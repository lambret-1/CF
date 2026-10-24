// SuperResApp/Features/video/VideoDownscaler.swift

import Foundation
import AVFoundation
import CoreImage
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
    public let pixelBuffer: CVPixelBuffer   // BGRA, sRGB, targetSize 尺寸
    public let presentationTime: CMTime

    public init(pixelBuffer: CVPixelBuffer, presentationTime: CMTime) {
        self.pixelBuffer = pixelBuffer
        self.presentationTime = presentationTime
    }
}

// MARK: - Downscaler

public final class VideoDownscaler: @unchecked Sendable {

    public struct Config {
        /// 目标短边（等比缩放的基准）
        public var targetShortSide: CGFloat = 272
        /// 输出尺寸对齐倍数。272 已是 16 的倍数。
        /// 若模型不强制 16 对齐，推荐 270 + alignment 2：
        ///   16:9 源 → 480×270，4x = 1920×1080，完全等比、无畸变。
        /// 强制 16 对齐会引入约 0.7% 的宽高比压缩。
        public var alignment: Int = 16
        /// Lanczos 的 ringing 过冲 clamp（防止 Real-ESRGAN 把白边放大成光晕）
        public var clampOvershoot: Bool = true

        public init() {}
    }

    public struct Metadata {
        public let sourceSize: CGSize        // composition.renderSize（已含旋转 + PAR）
        public let targetSize: CGSize        // 缩放后输出尺寸（已对齐，整数）
        public let duration: CMTime
        public let nominalFrameRate: Float   // 用于 processor 的抽帧 / 进度
    }

    public struct Output: @unchecked Sendable {
        public let metadata: Metadata
        public let frames: AsyncThrowingStream<VideoFrame, Error>
    }

    private let config: Config
    private let ciContext: CIContext
    private let outputColorSpace: CGColorSpace
    private let lanczos: CILanczosScaleTransform
    private let clampFilter: CIFilter?

    public init(config: Config = Config(), mtlDevice: MTLDevice? = nil) throws {
        self.config = config

        // 默认 working color space（线性 sRGB），关掉中间缓存
        let options: [CIContextOption: Any] = [.cacheIntermediates: false]
        if let device = mtlDevice {
            self.ciContext = CIContext(mtlDevice: device, options: options)
        } else {
            self.ciContext = CIContext(options: options)
        }

        // Real-ESRGAN 训练分布是 sRGB
        guard let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            throw VideoDownscalerError.renderFailed("sRGB 色彩空间不可用")
        }
        self.outputColorSpace = srgb

        self.lanczos = CILanczosScaleTransform()
        self.clampFilter = config.clampOvershoot ? CIFilter(name: "CIColorClamp") : nil
    }

    // MARK: - 公开接口

    /// 打开视频，返回元数据 + 拉模式帧流。
    /// 背压：消费者每 `next()` 一次才读一帧；`Task` 取消会触发 `reader.cancelReading()`。
    public func open(_ inputURL: URL) async throws -> Output {
        guard FileManager.default.fileExists(atPath: inputURL.path) else {
            throw VideoDownscalerError.inputNotFound(inputURL)
        }

        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw VideoDownscalerError.noVideoTrack
        }

        let duration = try await asset.load(.duration)
        guard duration.isNumeric, duration.seconds > 0 else {
            throw VideoDownscalerError.invalidDuration
        }
        let naturalFrameRate = try await videoTrack.load(.nominalFrameRate)

        // ① VideoComposition 处理旋转 / PAR / 时间轴
        // 注意：不要手动覆盖 renderSize —— propertiesOf 已经基于 preferredTransform
        //       和 pixel aspect ratio 计算出正确的"显示尺寸"。
        let composition = AVMutableVideoComposition(propertiesOf: asset)
        let sourceSize = composition.renderSize

        let fps: Double = naturalFrameRate > 0 ? Double(naturalFrameRate) : 30.0
        composition.frameDuration = CMTime(
            seconds: 1.0 / fps,
            preferredTimescale: 600
        )

        let targetSize = computeTargetSize(sourceSize: sourceSize)

        // ② Reader + VideoCompositionOutput（输出方向正确的全尺寸 BGRA）
        let reader: AVAssetReader
        do {
            reader = try AVAssetReader(asset: asset)
        } catch {
            throw VideoDownscalerError.readerInitFailed(error.localizedDescription)
        }

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
            throw VideoDownscalerError.readerStartFailed(
                reader.error?.localizedDescription ?? "未知错误"
            )
        }

        // ③ 目标尺寸的 buffer 池（每帧复用）
        let pool = try makePixelBufferPool(for: targetSize)

        let metadata = Metadata(
            sourceSize: sourceSize,
            targetSize: targetSize,
            duration: duration,
            nominalFrameRate: naturalFrameRate
        )

        // ④ 拉模式帧流。unfolding 闭包是串行调用的：
        //    消费端每 next() 一次，才执行一次缩放渲染。
        //    天然背压，没有无限堆积。
        let frames = AsyncThrowingStream<VideoFrame, Error>(
            unfolding: { [self] in
                do {
                    return try self.pullNextFrame(
                        reader: reader,
                        readerOutput: readerOutput,
                        targetSize: targetSize,
                        pool: pool
                    )
                } catch {
                    reader.cancelReading()
                    throw error
                }
            },
            onCancel: {
                reader.cancelReading()
            }
        )

        return Output(metadata: metadata, frames: frames)
    }

    // MARK: - 私有：单帧拉取（串行）

    private func pullNextFrame(
        reader: AVAssetReader,
        readerOutput: AVAssetReaderVideoCompositionOutput,
        targetSize: CGSize,
        pool: CVPixelBufferPool
    ) throws -> VideoFrame? {
        if let err = reader.error {
            throw err
        }
        guard let sample = readerOutput.copyNextSampleBuffer() else {
            reader.cancelReading(),
   // 读完后释放资源
            return nil
               }
        let pts = CMSampleBufferGetPresentationTime poolStamp(sample)
        guard let: imageBuffer = CMSampleBufferGet CImageBuffer(sample) else {
            return nil
        }
VP        let out = try renderScaled(from: imageixelBuffer, to: targetSize, pool: pool)
        return VideoFrame(pixelBuffer: out, presentationTime: pts)
    }

    // MARK: - 私有：尺寸计算

    private func computeTargetSize(sourceSize: CGSize) -> CGSize {
        let shortSide = min(sourceSize.width, sourceSize.height)
        guard shortSide > 0 else { return CGSize(width: 16, height: 16) }

        let scale = config.targetShortSide / shortSide
        let rawW  = sourceSize.width  * scale
        let rawH  = sourceSize.height * scale
        let align = max(1, config.alignment)

        // 用 round 而不是截断，减少对齐引入的偏差
        let alignedW = max(align, Int((rawW / CGFloat(align)).rounded()) * align)
        let alignedH = max(align, Int((rawH / CGFloat(align)).rounded()) * align)
        return CGSize(width: alignedW, height: alignedH)
    }

    // MARK: - 私有：Pixel Buffer 池

    private func makePixelBufferPool(for size: CGSize) throws -> CVPixelBufferPool {
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: Int(size.width),
            kCVPixelBufferHeightKey as String: Int(size.height),
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true
        ]
        let auxAttrs: [String: Any] = [
            kCVPixelBufferPoolMinimumBufferCountKey as String: 3
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(
            kCFAllocatorDefault,
            auxAttrs as CFDictionary,
            attrs as CFDictionary,
            &pool
        )
        guard status == kCVReturnSuccess, let result = pool else {
            throw VideoDownscalerError.pixelBufferPoolFailed
        }
        return result
    }

    // MARK: - 私有：CI Lanczos + Clamp 渲染到 sRGB

    /// aspectFill 等比缩放到覆盖 targetSize，再居中裁切（绝不拉伸）。
    private func renderScaled(
        from sourceBuffer: CVPixelBuffer,
        to targetSize: CGSizeBufferPool
    ) throws -> CVPixelBuffer {

        let input = CIImage(cvPixelBuffer: sourceBuffer)

        let scaleX = targetSize.width  / input.extent.width
        let scaleY = targetSize.height / input.extent.height
        let scale  = max(scaleX, scaleY)

        lanczos.inputImage  = input
        lanczos.scale       = Float(scale)
        lanczos.aspectRatio = 1.0

        guard var output = lanczos.outputImage else {
            throw VideoDownscalerError.renderFailed("Lanczos outputImage 为 nil")
        }

        // 居中裁切到目标尺寸
        let ext = output.extent
        let cropX = ext.origin.x + (ext.width  - targetSize.width)  / 2
        let cropY = ext.origin.y + (ext.height - targetSize.height) / 2
        let cropRect = CGRect(x: cropX, y: cropY,
                              width: targetSize.width,
                              height: targetSize.height)
        output = output
            .cropped(to: cropRect)
            .transformed(by: CGAffineTransform(
                translationX: -cropRect.origin.x,
                y: -cropRect.origin.y
            ))

        // 抑制 Lanczos ringing（超分模型会放大过冲）
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

        let renderRect = CGRect(origin: .zero, size: targetSize)
        ciContext.render(output, to: outBuffer, bounds: renderRect, colorSpace: outputColorSpace)
        return outBuffer
    }
}