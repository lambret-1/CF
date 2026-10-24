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
            throw NSError(domain: "VideoSR", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        
        let transformedSize = naturalSize.applying(preferredTransform)
        let pixelWidth = abs(transformedSize.width)
        let pixelHeight = abs(transformedSize.height)
        
        var targetWidth = Int(pixelWidth) * scaleFactor
        var targetHeight = Int(pixelHeight) * scaleFactor
        targetWidth = targetWidth / 2 * 2
        targetHeight = targetHeight / 2 * 2
        
        let targetMaxFPS: Double = 30.0
        var skipInterval: Int = 1
        if nominalFrameRate > targetMaxFPS {
            skipInterval = Int(round(nominalFrameRate / targetMaxFPS))
        }
        
        await logInfo("🎬 开始流水线并发处理：\(Int(pixelWidth))x\(Int(pixelHeight)) -> \(targetWidth)x\(targetHeight)")
        if skipInterval > 1 {
            await logInfo("⚡️ 抽帧生效：原帧率 \(Int(nominalFrameRate))fps -> 目标 \(Int(targetMaxFPS))fps")
        }
        
        let reader = try AVAssetReader(asset: asset)
        let videoOutputSettings: [String: Any] = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
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
        }
        
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
        
        guard reader.startReading() else { throw reader.error! }
        guard writer.startWriting() else { throw writer.error! }
        
        writer.startSession(atSourceTime: .zero)
        await logInfo("⚙️ 编码器启动成功，进入多线程并发超分模式...")
        
        let totalFrames = max(1.0, CMTimeGetSeconds(duration) * nominalFrameRate)
        
        // ⭐️ 并发控制核心变量
        let condition = NSCondition()
        var readFrameIndex = 0
        var writeFrameIndex = 0
        var framesToSkip = 0
        
        // 缓存字典：存放超分完成的帧，以 Index 为 Key
        var completedFrames: [Int: CMSampleBuffer] = [:]
        var isReadingFinished = false
        
        // 生产者（读取线程）
        let producerQueue = DispatchQueue(label: "video.producer")
        writerVideoInput.requestMediaDataWhenReady(on: producerQueue) {
            while writerVideoInput.isReadyForMoreMediaData {
                condition.lock()
                
                if self.isCancelled {
                    condition.broadcast()
                    condition.unlock()
                    reader.cancelReading()
                    writer.cancelWriting()
                    return
                }
                
                // 如果缓存积压太多，暂停读取，防止内存爆炸
                if readFrameIndex - writeFrameIndex > 10 {
                    condition.unlock()
                    Thread.sleep(forTimeInterval: 0.01)
                    continue
                }
                
                // 抽帧判断
                if framesToSkip > 0 {
                    framesToSkip -= 1
                    readFrameIndex += 1
                    condition.unlock()
                    continue
                }
                framesToSkip = skipInterval - 1
                
                guard let videoSampleBuffer = readerVideoOutput.copyNextSampleBuffer() else {
                    isReadingFinished = true
                    condition.broadcast()
                    condition.unlock()
                    break
                }
                
                let currentIdx = readFrameIndex
                readFrameIndex += 1
                condition.unlock()
                
                // 丢给后台超分任务
                let semaphore = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    autoreleasepool {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else {
                            semaphore.signal(); return
                        }
                        let timestamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
                        let ciImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: preferredTransform)
                        
                        if let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) {
                            var superResCGImage: CGImage?
                            let dispatchGroup = DispatchGroup()
                            dispatchGroup.enter()
                            
                            Task {
                                superResCGImage = try? await SuperResolver.shared.fastUpscale(image: cgImage, modelID: modelID)
                                dispatchGroup.leave()
                            }
                            dispatchGroup.wait()
                            
                            if let resImage = superResCGImage,
                               let newBuffer = self.pixelBuffer(from: resImage, width: targetWidth, height: targetHeight),
                               let newSampleBuffer = self.createSampleBuffer(from: newBuffer, timestamp: timestamp) {
                                
                                condition.lock()
                                completedFrames[currentIdx] = newSampleBuffer
                                condition.broadcast() // 唤醒消费者
                                condition.unlock()
                            }
                        }
                        semaphore.signal()
                    }
                }
            }
        }
        
        // 消费者（写入线程）
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let consumerQueue = DispatchQueue(label: "video.consumer")
            writerVideoInput.requestMediaDataWhenReady(on: consumerQueue) {
                while writerVideoInput.isReadyForMoreMediaData {
                    condition.lock()
                    
                    if self.isCancelled {
                        condition.unlock()
                        continuation.resume(throwing: NSError(domain: "VideoSR", code: 499, userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        return
                    }
                    
                    // 如果当前需要的帧还没算完，等待
                    if completedFrames[writeFrameIndex] == nil {
                        if isReadingFinished && readFrameIndex == writeFrameIndex {
                            // 所有帧处理完毕
                            condition.unlock()
                            writerVideoInput.markAsFinished()
                            writerAudioInput?.markAsFinished()
                            writer.finishWriting {
                                if writer.status == .completed {
                                    continuation.resume()
                                } else {
                                    continuation.resume(throwing: writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: nil))
                                }
                            }
                            return
                        }
                        
                        // 没算完就挂起等待
                        condition.wait()
                        condition.unlock()
                        continue
                    }
                    
                    // 顺序写入
                    if let buffer = completedFrames.removeValue(forKey: writeFrameIndex) {
                        writeFrameIndex += 1
                        
                        // 更新进度
                        let progress = min(1.0, Double(writeFrameIndex) / totalFrames)
                        DispatchQueue.main.async { self.progressHandler?(progress) }
                        
                        condition.unlock()
                        writerVideoInput.append(buffer)
                    } else {
                        condition.unlock()
                    }
                }
            }
            
            // 音频写入保持独立
            if let audioInput = writerAudioInput, let audioOutput = readerAudioOutput {
                audioInput.requestMediaDataWhenReady(on: consumerQueue) {
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
        await logInfo("✅ 并发超分处理完成！")
    }
    
    // MARK: - 日志辅助
    private func logInfo(_ msg: String) async {
        await MainActor.run { AppLogger.shared.log("[视频管道] \(msg)", isError: false) }
    }
    
    private func logError(_ msg: String) async {
        await MainActor.run { AppLogger.shared.log("[视频管道] \(msg)",还是 isError: true) }
    }
    
    // MARK感觉: - 转换工具
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