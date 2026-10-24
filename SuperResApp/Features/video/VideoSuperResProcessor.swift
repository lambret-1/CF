// SuperResApp/Features/video/VideoSuperResProcessor.swift

import Foundation
import AVFoundation
import CoreImage
import UIKit

/// 视频超分核心管道（基于 AVFoundation 的流式处理）
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
            throw NSError(domain: "VideoSR", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let transformedSize = naturalSize.applying(preferredTransform)
        let pixelWidth = abs(transformedSize.width)
        let pixelHeight = abs(transformedSize.height)
        
        // 计算超分尺寸，必须保证是偶数，否则编码器会崩溃
        var targetWidth = Int(pixelWidth) * scaleFactor
        var targetHeight = Int(pixelHeight) * scaleFactor
        targetWidth = targetWidth / 2 * 2
        targetHeight = targetHeight / 2 * 2
        
        // 1. 初始化 Reader
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
        }
        
        // 2. 初始化 Writer (改用 MOV 容器 + HEVC 编码，抗高分辨率压力)
        // 注意：调用此方法前，ViewModel 里的 outputURL 后缀最好改成 .mov
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        let videoCompressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Int(targetWidth * targetHeight * 4),
            AVVideoMaxKeyFrameIntervalKey: 30
        ]
        
        // ⭐️ 核心修复：使用 HEVC 编码器，它支持 8K 甚至更高
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
            throw reader.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "Reader 启动失败: \(reader.error?.localizedDescription ?? "")"])
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "Writer 启动失败: \(writer.error?.localizedDescription ?? "")"])
        }
        
        writer.startSession(atSourceTime: .zero)
        
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
                        continuation.resume(throwing: NSError(domain: "VideoSR", code: 499, userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        return
                    }
                    
                    guard let videoSampleBuffer = readerVideoOutput.copyNextSampleBuffer() else {
                        writerVideoInput.markAsFinished()
                        writerAudioInput?.markAsFinished()
                        
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                // ⭐️ 如果这里报错，通常是编码器崩了或者内存不够
                                let err = writer.error?.localizedDescription ?? "未知错误"
                                continuation.resume(throwing: NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "视频合成失败: \(err)"]))
                            }
                        }
                        return
                    }
                    
                    autoreleasepool {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { return }
                        let timestamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
                        
                        let ciImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: preferredTransform)
                        
                        // 提取 CGImage
                        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
                        
                        let semaphore = DispatchSemaphore(value: 0)
                        var superResCGImage: CGImage?
                        
                        Task {
                            do {
                                // 调用超分 (强制极速模式)
                                superResCGImage = try await SuperResolver.shared.fastUpscale(
                                    image: cgImage,
                                    modelID: modelID
                                )
                            } catch {
                                print("⚠️ 单帧超分失败: \(error.localizedDescription)")
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
    
    private func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary // 允许硬件加速
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