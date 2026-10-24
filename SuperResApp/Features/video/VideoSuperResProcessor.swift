// SuperResApp/Features/video/VideoSuperResProcessor.swift

import Foundation
import AVFoundation
import CoreImage
import UIKit

actor VideoSuperResProcessor {
    
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    private var isCancelled = false
    private var progressHandler: ((Double) -> Void)?
    
    func cancel() {
        isCancelled = true
    }
    
    func processVideo(
        inputURL: URL,
        outputURL: URL,
        modelID: String,
        scaleFactor: Int,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        
        self.isCancelled = false
        self.progressHandler = progressHandler
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        let asset = AVAsset(url: inputURL)
        
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            await logError("找不到视频轨道")
            throw NSError(domain: "VideoSR", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let transformedSize = naturalSize.applying(preferredTransform)
        let pixelWidth = abs(transformedSize.width)
        let pixelHeight = abs(transformedSize.height)
        
        var targetWidth = Int(pixelWidth) * scaleFactor
        var targetHeight = Int(pixelHeight) * scaleFactor
        targetWidth = targetWidth / 2 * 2
        targetHeight = targetHeight / 2 * 2
        
        // ⭐️ 记录初始信息
        await logInfo("🎬 开始处理视频：\(Int(pixelWidth))x\(Int(pixelHeight)) -> \(targetWidth)x\(targetHeight)")
        
        let reader = try AVAssetReader(asset: asset)
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        readerVideoOutput.alwaysCopiesSampleData = false
        reader.add(readerVideoOutput)
        
        var readerAudioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false
            ]
            readerAudioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioOutputSettings)
            if let audioOutput = readerAudioOutput { reader.add(audioOutput) }
            await logInfo("🔊 已找到音频轨道，准备混流")
        } else {
            await logInfo("🔇 原视频无音频轨道")
        }
        
        // 改用 MOV + HEVC
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        let videoCompressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Int(targetWidth * targetHeight * 4),
            AVVideoMaxKeyFrameIntervalKey: 30
        ]
        
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc, 
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: videoCompressionProperties
        ])
        writerVideoInput.expectsMediaDataInRealTime = false
        writer.add(writerVideoInput)
        
        var writerAudioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128000
            ]
            writerAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
            if let audioInput = writerAudioInput { writer.add(audioInput) }
        }
        
        guard reader.startReading() else {
            let err = reader.error?.localizedDescription ?? "未知"
            await logError("Reader 启动失败: \(err)")
            throw reader.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "Reader 启动失败: \(err)"])
        }
        guard writer.startWriting() else {
            let err = writer.error?.localizedDescription ?? "未知"
            await logError("Writer 启动失败: \(err)")
            throw writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "Writer 启动失败: \(err)"])
        }
        
        writer.startSession(atSourceTime: .zero)
        await logInfo("⚙️ 编码器启动成功，开始逐帧超分...")
        
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = max(1.0, CMTimeGetSeconds(duration) * Double(nominalFrameRate))
        var currentFrame: Double = 0
        
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let queue = DispatchQueue(label: "com.superres.video.processing")
            
            writerVideoInput.requestMediaDataWhenReady(on: queue) { [weak self] in
                guard let self = self else { return }
                
                while writerVideoInput.isReadyForMoreMediaData {
                    if self.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        Task { await self.logWarning("⏹ 用户取消了视频处理") }
                        continuation.resume(throwing: NSError(domain: "VideoSR", code: 499, userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        return
                    }
                    
                    guard let videoSampleBuffer = readerVideoOutput.copyNextSampleBuffer() else {
                        writerVideoInput.markAsFinished()
                        writerAudioInput?.markAsFinished()
                        
                        writer.finishWriting {
                            if writer.status == .completed {
                                Task { await self.logInfo("✅ 视频超分处理完成！") }
                                continuation.resume()
                            } else {
                                let err = writer.error?.localizedDescription ?? "未知"
                                Task { await self.logError("❌ 视频合成失败: \(err)") }
                                continuation.resume(throwing: NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "视频合成失败: \(err)"]))
                            }
                        }
                        return
                    }
                    
                    autoreleasepool {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { return }
                        let timestamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
                        
                        let ciImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: preferredTransform)
                        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
                        
                        let semaphore = DispatchSemaphore(value: 0)
                        var superResCGImage: CGImage?
                        
                        Task {
                            do {
                                superResCGImage = try await SuperResolver.shared.fastUpscale(
                                    image: cgImage,
                                    modelID: modelID
                                )
                            } catch {
                                let frameIndex = Int(currentFrame)
                                Task { await self.logError("⚠️ 第 \(frameIndex) 帧超分失败: \(error.localizedDescription)") }
                            }
                            semaphore.signal()
                        }
                        
                        semaphore.wait()
                        
                        if let superResCGImage = superResCGImage {
                            if let newBuffer = self.pixelBuffer(from: superResCGImage, width: targetWidth, height: targetHeight) {
                                if let newSampleBuffer = self.createSampleBuffer(from: newBuffer, timestamp: timestamp) {
                                    writerVideoInput.append(newSampleBuffer)
                                }
                            }
                        }
                        
                        currentFrame += 1
                        let progress = min(1.0, currentFrame / totalFrames)
                        DispatchQueue.main.async { self.progressHandler?(progress) }
                    }
                }
            }
            
            if let audioInput = writerAudioInput, let audioOutput = readerAudioOutput {
                audioInput.requestMediaDataWhenReady(on: queue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let audioSampleBuffer = audioOutput.copyNextSampleBuffer() else {
                            audioInput.markAsFinished()
                            return
                        }
                        audioInput.append(audioSampleBuffer)
                    }
                }
            }
        }
    }
    
    // MARK: - 日志辅助
    private func logInfo(_ msg: String) async {
        await MainActor.run { AppLogger.shared.log("[视频管道] \(msg)", isError: false) }
    }
    
    private func logError(_ msg: String) async {
        await MainActor.run { AppLogger.shared.log("[视频管道] \(msg)", isError: true) }
    }
    
    private func logWarning(_ msg: String) async {
        await MainActor.run { AppLogger.shared.log("[视频管道] \(msg)", isError: false) }
    }
    
    // MARK: - 转换工具 (保持原样)
    private func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary
        ]
        var pixelBuffer: CVPixelBuffer?
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pixelBuffer)
        
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
    
    private func createSampleBuffer(from pixelBuffer: CVPixelBuffer, timestamp: CMTime) -> CMSampleBuffer? {
        var sampleBuffer: CMSampleBuffer?
        var timingInfo = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: timestamp, decodeTimeStamp: .invalid)
        
        var formatDescription: CMFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixelBuffer, formatDescriptionOut: &formatDescription)
        
        guard let format = formatDescription else { return nil }
        
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: format,
            sampleTiming: &timingInfo,
            sampleBufferOut: &sampleBuffer
        )
        
        return sampleBuffer
    }
}