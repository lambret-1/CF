// SuperResApp/Features/video/VideoDownscaler.swift

import Foundation
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreVideo
import Metal

// MARK: - 错误
public enum VideoDownscalerError: LocalizedError {
    case inputNotFound(URL)
    case noVideoTrack
    case invalidDuration
    case readerInitFailed(String)
    case readerStartFailed(String)
    case pixelBufferPoolFailed
    case renderFailed(String)

    public var errorDescription: String? {
        switch self {
        case .inputNotFound(let url):     return "输入视频不存在: \(url.lastPathComponent)"
        case .noVideoTrack:               return "找不到视频轨道"
        case .invalidDuration:            return "视频时长无效"
        case .readerInitFailed(let s):    return "创建 AVAssetReader 失败: \(s)"
        case .readerStartFailed(let s):   return "启动 reader 失败: \(s)"
        case .pixelBufferPoolFailed:      return "创建像素缓冲池失败"
        case .renderFailed(let s):        return "图像渲染失败: \(s)"
        }
    }
}

// MARK: - 帧
public struct VideoFrame: @unchecked Sendable {
    public let pixelBuffer: CVPixelBuffer
    public let presentationTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}

// MARK: - Downscaler
public final class VideoDownscaler: @unchecked Sendable {

    public struct Config {
        /// ⭐️ 改为可选：nil 表示不降采样（保持原尺寸），默认 272
        public var targetShortSide: CGFloat?
        public var alignment: Int
        public var clampOvershoot: Bool
        
        public init(
            targetShortSide: CGFloat? = 272,
            alignment: Int = 16,
            clampOvershoot: Bool = true
        ) {
            self.targetShortSide = targetShortSide
            self.alignment = alignment
            self.clampOvershoot = clampOvershoot
        }
    }

    public struct Metadata {
        public let sourceSize: CGSize
        public let targetSize: CGSize
        public let duration: CMTime
        public let nominalFrameRate: Float
    }

    public struct Output: @unchecked Sendable {
        public let metadata: Metadata
        public let frames: AsyncThrowingStream<VideoFrame, Error>
    }

    private let config: Config
    private let ciContext: CIContext
    private let outputColorSpace: CGColorSpace
    private let lanczosFilter: CIFilter
    private let clampFilter: CIFilter?

    private func logInfo(_ msg: String) {
        Task { @MainActor in AppLogger.shared.log("[降采样] \(msg)", isError: false) }
    }

    private func logError(_ msg: String) {
        Task { @MainActor in AppLogger.shared.log("[降采样] ❌ \(msg)", isError: true) }
    }

    public init(config: Config = Config(), mtlDevice: MTLDevice? = nil) throws {
        self.config = config

        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = mtlDevice {
            self.ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            self.ciContext = CIContext(options: options)
        }

        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw VideoDownscalerError.renderFailed("sRGB 色彩空间不可用")
        }
        self.outputColorSpace = srgb

        self.lanczosFilter = CIFilter.lanczosScaleTransform()
        self.clampFilter = config.clampOvershoot ? CIFilter.colorClamp() : nil
    }

    public func open(_ inputURL: URL) async throws -> Output {
        logInfo("==== 开始初始化降采样 ====")
        
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            logError("找不到输入文件: \(inputURL.lastPathComponent)")
            throw VideoDownscalerError.inputNotFound(inputURL)
        }

        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            logError("找不到视频轨道")
            throw VideoDownscalerError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            logError("时长无效")
            throw VideoDownscalerError.invalidDuration
        }
        let naturalFrameRate = try await videoTrack.load(.nominalFrameRate)

        let composition = AVMutableVideoComposition(propertiesOf: asset)
        let sourceSize = composition.renderSize

        let fps: Double = naturalFrameRate > 0 ? Double(naturalFrameRate) : 30.0
        composition.frameDuration = CMTime(seconds: 1.0 / fps, preferredTimescale: 600)

        let targetSize = computeTargetSize(sourceSize: sourceSize)

        logInfo("源尺寸=\(Int(sourceSize.width))x\(Int(sourceSize.height))")
        logInfo("目标尺寸=\(Int(targetSize.width))x\(Int(targetSize.height)) (对齐=\(config.alignment))")
        logInfo("时长=\(String(format: "%.2f", duration.seconds))s, 帧率=\(String(format: "%.2f", fps))fps")

        let reader = try AVAssetReader(asset: asset)
        let readerOutput = AVAssetReaderVideoCompositionOutput(
            videoTracks: [videoTrack],
            videoSettings: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )
        readerOutput.videoComposition = composition
        readerOutput.alwaysCopiesSampleData = false

        guard reader.canAdd(readerOutput) else {
            throw VideoDownscalerError.readerStartFailed("无法添加 videoCompositionOutput")
        }
        reader.add(readerOutput)

        guard reader.startReading() else {
            throw VideoDownscalerError.readerStartFailed(reader.error?.localizedDescription ?? "未知错误")
        }

        let pool = try makePixelBufferPool(for: targetSize)

        let metadata = Metadata(
            sourceSize: sourceSize,
            targetSize: targetSize,
            duration: duration,
            nominalFrameRate: naturalFrameRate
        )

        let frames = AsyncThrowingStream<VideoFrame, Error> { [self] continuation in
            // 在流取消时清理 reader
            continuation.onTermination = { _ in
                reader.cancelReading()
            }
            
            do {
                var frameCount = 0
                while let frame = try self.pullNextFrame(reader: reader, readerOutput: readerOutput, targetSize: targetSize, pool: pool) {
                    continuation.yield(frame)
                    frameCount += 1
                    if frameCount % 50 == 0 {
                        self.logInfo("已提取 \(frameCount) 帧供超分使用")
                    }
                }
                self.logInfo("降采样读取结束，共提取 \(frameCount) 帧")
                continuation.finish()
            } catch {
                self.logError("提取帧失败: \(error.localizedDescription)")
                continuation.finish(throwing: error)
            }
        }

        return Output(metadata: metadata, frames: frames)
    }

    private func pullNextFrame(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderVideoCompositionOutput,
        targetSize: CGSize,
        pool: CVPixelBufferPool
    ) throws -> VideoFrame? {
        if let err = reader.error { throw err }
        guard let sample = readerOutput.copyNextSampleBuffer() else { return nil }
        
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard let imageBuffer = CMSampleBufferGetImageBuffer(sample) else { return nil }
        let out = try renderScaled(from: imageBuffer, to: targetSize, pool: pool)
        return VideoFrame(pixelBuffer: out, presentationTime: pts)
    }

    private func computeTargetSize(sourceSize: CGSize) -> CGSize {
        let shortSide = min(sourceSize.width, sourceSize.height)
        guard shortSide > 0 else { return CGSize(width: 16, height: 16) }

        // ⭐️ 如果 targetShortSide 为 nil，直接使用原短边（不缩放），否则按指定值缩放
        let targetShort = config.targetShortSide ?? shortSide
        let scale = targetShort / shortSide
        let rawW  = sourceSize.width  * scale
        let rawH  = sourceSize.height * scale
        let align = max(1, config.alignment)

        let alignedW = max(align, Int((rawW / CGFloat(align)).rounded()) * align)
        let alignedH = max(align, Int((rawH / CGFloat(align)).rounded()) * align)
        return CGSize(width: alignedW, height: alignedH)
    }

    private func makePixelBufferPool(for size: CGSize) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let auxAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault, auxAttrs as CFDictionary, attrs as CFDictionary, &pool)
        guard status == kCVReturnSuccess, let result = pool else {
            throw VideoDownscalerError.pixelBufferPoolFailed
        }
        return result
    }

    private func renderScaled(from sourceBuffer: CVPixelBuffer, to targetSize: CGSize, pool: CVPixelBufferPool) throws -> CVPixelBuffer {
        let input = CIImage(cvPixelBuffer: sourceBuffer)

        // 如果不是不降采样，需要执行 Lanczos 缩放
        var output = input
        if config.targetShortSide != nil {
            let scaleX = targetSize.width  / input.extent.width
            let scaleY = targetSize.height / input.extent.height
            let scale  = max(scaleX, scaleY)

            lanczosFilter.setValue(input, forKey: kCIInputImageKey)
            lanczosFilter.setValue(scale, forKey: kCIInputScaleKey)
            lanczosFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)

            guard let scaledImage = lanczosFilter.outputImage else {
                throw VideoDownscalerError.renderFailed("Lanczos outputImage 为 nil")
            }
            output = scaledImage
        }

        // 居中裁切对齐
        let ext = output.extent
        let cropX = ext.origin.x + (ext.width  - targetSize.width)  / 2
        let cropY = ext.origin.y + (ext.height - targetSize.height) / 2
        let cropRect = CGRect(x: cropX, y: cropY, width: targetSize.width, height: targetSize.height)
        
        output = output
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))

        // 消除 Lanczos 锐化过冲
        if let clamp = clampFilter {
            clamp.setValue(output, forKey: kCIInputImageKey)
            clamp.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputMinComponents")
            clamp.setValue(CIVector(x: 1, y: 1, z: 1, w: 1), forKey: "inputMaxComponents")
            if let clamped = clamp.outputImage { output = clamped }
        }

        var dst: CVPixelBuffer?
        let status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &dst)
        guard status == kCVReturnSuccess, let outBuffer = dst else {
            throw VideoDownscalerError.pixelBufferPoolFailed
        }

        ciContext.render(output, to: outBuffer, bounds: CGRect(origin: .zero, size: targetSize), colorSpace: outputColorSpace)
        return outBuffer
    }
}