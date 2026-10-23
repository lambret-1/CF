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
    
    /// 取消当前处理任务
    func cancel() {
        isCancelled = true
    }
    
    /// 开始处理视频
    /// - Parameters:
    ///   - inputURL: 原始视频本地路径
    ///   - outputURL: 输出视频本地路径
    ///   - modelID: 超分模型 ID
    ///   - scaleFactor: 放大倍数（如 4 倍）
    ///   - progressHandler: 进度回调 (0.0 ~ 1.0)
    func processVideo(
        inputURL: URL,
        outputURL: URL,
        modelID: String,
        scaleFactor: Int,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        
        self.isCancelled = false
        self.progressHandler = progressHandler
        
        // 1. 清理可能存在的旧输出文件
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
        }
        
        let asset = AVAsset(url: inputURL)
        
        // 2. 读取视频轨道与音频轨道
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoSR", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        
        // 3. 计算真实的分辨率和旋转方向 (处理手机拍摄的视频自动旋转问题)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        
        let transformedSize = naturalSize.applying(preferredTransform)
        let pixelWidth = abs(transformedSize.width)
        let pixelHeight = abs(transformedSize.height)
        
        // 计算目标超分尺寸 (必须是偶数，否则 H.264 编码会失败)
        let targetWidth = (pixelWidth * CGFloat(scaleFactor)).rounded(.down) / 2 * 2
        let targetHeight = (pixelHeight * CGFloat(scaleFactor)).rounded(.down) / 2 * 2
        
        // 4. 配置 AssetReader (读取原视频)
        let reader = try AVAssetReader(asset: asset)
        
        // 视频读取配置：输出为 BGRA 格式
        let videoOutputSettings: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: videoOutputSettings)
        readerVideoOutput.alwaysCopiesSampleData = false // 性能优化：不拷贝数据
        reader.add(readerVideoOutput)
        
        // 音频读取配置：原声透传（读取 PCM 格式）
        var readerAudioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false
            ]
            readerAudioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: audioOutputSettings)
            if let audioOutput = readerAudioOutput {
                reader.add(audioOutput)
            }
        }
        
        // 5. 配置 AssetWriter (写入新视频)
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        
        // 视频写入配置：H.264 编码
        let videoCompressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Int(targetWidth * targetHeight * 5), // 动态计算码率
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: Int(targetWidth),
            AVVideoHeightKey: Int(targetHeight),
            AVVideoCompressionPropertiesKey: videoCompressionProperties
        ])
        writerVideoInput.expectsMediaDataInRealTime = false // 允许慢速处理，不需要实时
        writer.add(writerVideoInput)
        
        // 音频写入配置：AAC 编码
        var writerAudioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128000
            ]
            writerAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
            if let audioInput = writerAudioInput {
                writer.add(audioInput)
            }
        }
        
        // 6. 启动读写引擎
        guard reader.startReading() else {
            throw reader.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "Reader 启动失败"])
        }
        guard writer.startWriting() else {
            throw writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "Writer 启动失败"])
        }
        
        writer.startSession(atSourceTime: .zero)
        
        // 计算总帧数用于进度条估算
        let nominalFrameRate = try await videoTrack.load(.nominalFrameRate)
        let totalFrames = max(1.0, CMTimeGetSeconds(duration) * Double(nominalFrameRate))
        var currentFrame: Double = 0
        
        // 7. 核心处理循环 (使用 continuation 将闭包回调转为 async/await)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let processingQueue = DispatchQueue(label: "com.superres.video.processing")
            
            writerVideoInput.requestMediaDataWhenReady(on: processingQueue) { [weak self] in
                guard let self = self else { return }
                
                while writerVideoInput.isReadyForMoreMediaData {
                    // 检查用户是否取消了任务
                    if self.isCancelled {
                        reader.cancelReading()
                        writer.cancelWriting()
                        continuation.resume(throwing: NSError(domain: "VideoSR", code: 499, userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        return
                    }
                    
                    // 读取下一帧视频
                    guard let videoSampleBuffer = readerVideoOutput.copyNextSampleBuffer() else {
                        // 视频帧读取完毕
                        writerVideoInput.markAsFinished()
                        writerAudioInput?.markAsFinished()
                        
                        writer.finishWriting {
                            if writer.status == .completed {
                                continuation.resume()
                            } else {
                                continuation.resume(throwing: writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: [NSLocalizedDescriptionKey: "视频合成失败"]))
                            }
                        }
                        return
                    }
                    
                    // ⭐️ 极其重要：autoreleasepool 防止内存爆炸
                    autoreleasepool {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { return }
                        let timestamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
                        
                        // 把视频帧转成 CGImage
                        let ciImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: preferredTransform) // 应用旋转
                        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
                        
                        // 使用信号量同步等待超分结果（因为 requestMediaDataWhenReady 是同步闭包）
                        let semaphore = DispatchSemaphore(value: 0)
                        var superResCGImage: CGImage?
                        
                        Task {
                            do {
                                // ⭐️ 强制使用 fastUpscale，视频处理必须用极速模式
                                superResCGImage = try await SuperResolver.shared.fastUpscale(
                                    image: cgImage,
                                    modelID: modelID
                                )
                            } catch {
                                print("单帧超分失败: \(error)")
                            }
                            semaphore.signal()
                        }
                        
                        semaphore.wait()
                        
                        // 如果超分成功，转回 Buffer 并写入
                        if let superResCGImage = superResCGImage {
                            if let newBuffer = self.pixelBuffer(from: superResCGImage, width: Int(targetWidth), height: Int(targetHeight)) {
                                if let newSampleBuffer = self.createSampleBuffer(from: newBuffer, timestamp: timestamp) {
                                    writerVideoInput.append(newSampleBuffer)
                                }
                            }
                        }
                        
                        // 更新进度
                        currentFrame += 1
                        let progress = min(1.0, currentFrame / totalFrames)
                        DispatchQueue.main.async {
                            self.progressHandler?(progress)
                        }
                    }
                }
            }
            
            // 音频流并行处理（直接透传，无需超分）
            if let audioInput = writerAudioInput, let audioOutput = readerAudioOutput {
                audioInput.requestMediaDataWhenReady(on: processingQueue) {
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
    
    // MARK: - 辅助转换工具
    
    /// CGImage -> CVPixelBuffer
    private func pixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary // 允许 GPU 硬件加速
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
    
    /// CVPixelBuffer + 时间戳 -> CMSampleBuffer
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