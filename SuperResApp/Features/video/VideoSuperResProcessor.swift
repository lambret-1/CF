// SuperResApp/Features/video/VideoSuperResProcessor.swift

import Foundation
import AVFoundation
import CoreImage
import UIKit

final class VideoSuperResProcessor {
    
    // MARK: - 基础
    private let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])
    
    private let stateLock = NSLock()
    private var _isCancelled = false
    private var isCancelled: Bool {
        get { stateLock.withLock { _isCancelled } }
        set { stateLock.withLock { _isCancelled = newValue } }
    }
    
    func cancel() { isCancelled = true }
    
    // MARK: - 日志（非阻塞，可在任意队列调用）
    private func logInfo(_ msg: String) {
        Task { @MainActor in
            AppLogger.shared.log("[视频管道] \(msg)", isError: false)
        }
    }
    private func logError(_ msg: String) {
        Task { @MainActor in
            AppLogger.shared.log("[视频管道] ❌ \(msg)", isError: true)
        }
    }
    
    // MARK: - 保证 continuation 只 resume 一次
    private final class ResumeBox {
        private let lock = NSLock()
        private var done = false
        func once(_ action: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            action()
        }
    }
    
    // MARK: - 主流程
    func processVideo(
        inputURL: URL,
        outputURL: URL,
        modelID: String,
        scaleFactor: Int,
        progressHandler: @escaping (Double) -> Void
    ) async throws {
        
        isCancelled = false
        logInfo("==== 开始超分任务 ====")
        logInfo("input=\(inputURL.lastPathComponent) model=\(modelID) scale=\(scaleFactor)x")
        
        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
            logInfo("已清理旧输出文件")
        }
        
        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            logError("找不到视频轨道")
            throw NSError(domain: "VideoSR", code: 404,
                          userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first
        
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))
        
        logInfo("源尺寸=\(naturalSize) transform=\(preferredTransform)")
        logInfo("时长=\(String(format: "%.2f", CMTimeGetSeconds(duration)))s 原帧率=\(String(format: "%.2f", nominalFrameRate))fps")
        
        let transformedSize = naturalSize.applying(preferredTransform)
        var targetWidth  = Int(abs(transformedSize.width))  * scaleFactor
        var targetHeight = Int(abs(transformedSize.height)) * scaleFactor
        targetWidth  = (targetWidth  / 2) * 2
        targetHeight = (targetHeight / 2) * 2
        
        let targetMaxFPS: Double = 30.0
        var skipInterval = 1
        if nominalFrameRate > targetMaxFPS {
            skipInterval = max(1, Int(round(nominalFrameRate / targetMaxFPS)))
        }
        
        logInfo("🎬 目标尺寸=\(targetWidth)x\(targetHeight) 抽帧间隔=\(skipInterval)")
        
        // ---------- Reader ----------
        let reader = try AVAssetReader(asset: asset)
        let readerVideoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        readerVideoOutput.alwaysCopiesSampleData = false
        reader.add(readerVideoOutput)
        
        var readerAudioOutput: AVAssetReaderTrackOutput?
        if let audioTrack = audioTrack {
            let ao = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: [
                AVFormatIDKey: kAudioFormatLinearPCM,
                AVLinearPCMIsFloatKey: false,
                AVLinearPCMBitDepthKey: 16,
                AVLinearPCMIsNonInterleaved: false
            ])
            reader.add(ao)
            readerAudioOutput = ao
            logInfo("🔊 已找到音频轨道，准备混流")
        } else {
            logInfo("🔇 无音频轨道")
        }
        
        // ---------- Writer ----------
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(targetWidth * targetHeight) * 2.5),
                AVVideoMaxKeyFrameIntervalKey: 30,
                AVVideoAllowFrameReorderingKey: true
            ]
        ])
        writerVideoInput.expectsMediaDataInRealTime = false
        writer.add(writerVideoInput)
        
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: writerVideoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: targetWidth,
                kCVPixelBufferHeightKey as String: targetHeight,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )
        
        var writerAudioInput: AVAssetWriterInput?
        if audioTrack != nil {
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128_000
            ])
            writer.add(ai)
            writerAudioInput = ai
        }
        
        guard reader.startReading() else {
            logError("reader.startReading 失败: \(String(describing: reader.error))")
            throw reader.error ?? NSError(domain: "VideoSR", code: -1)
        }
        guard writer.startWriting() else {
            logError("writer.startWriting 失败: \(String(describing: writer.error))")
            throw writer.error ?? NSError(domain: "VideoSR", code: -2)
        }
        logInfo("⚙️ reader/writer 启动成功 status(reader)=\(reader.status.rawValue) status(writer)=\(writer.status.rawValue)")
        
        // ---------- 共享状态 ----------
        let condition = NSCondition()
        var readFrameIndex  = 0
        var writeFrameIndex = 0
        var framesToSkip    = 0
        var completedBuffers:    [Int: CVPixelBuffer] = [:]
        var completedTimestamps: [Int: CMTime]        = [:]
        var isReadingFinished = false
        var firstTimestamp: CMTime?
        
        let inFlightLimit = 8
        let totalOutputFrames = max(1, Int(CMTimeGetSeconds(duration) * nominalFrameRate) / skipInterval)
        logInfo("预计输出帧数=\(totalOutputFrames)")
        
        // ---------- Producer ----------
        let producerQueue = DispatchQueue(label: "video.producer", qos: .userInitiated)
        producerQueue.async { [weak self] in
            guard let self else { return }
            self.logInfo("▶️ Producer 启动")
            
            var readCount = 0
            var skippedCount = 0
            var srFailedCount = 0
            var bufferFailedCount = 0
            
            while true {
                if self.isCancelled {
                    self.logInfo("🛑 Producer 检测到取消")
                    break
                }
                
                // 背压
                condition.lock()
                while readFrameIndex - writeFrameIndex >= inFlightLimit && !self.isCancelled {
                    condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                }
                let cancelNow = self.isCancelled
                condition.unlock()
                if cancelNow { break }
                
                // 抽帧
                if framesToSkip > 0 {
                    framesToSkip -= 1
                    _ = readerVideoOutput.copyNextSampleBuffer()
                    skippedCount += 1
                    continue
                }
                framesToSkip = skipInterval - 1
                
                guard let sb = readerVideoOutput.copyNextSampleBuffer() else {
                    self.logInfo("📭 Reader 读取结束 reader.status=\(reader.status.rawValue) error=\(String(describing: reader.error))")
                    condition.lock()
                    isReadingFinished = true
                    condition.broadcast()
                    condition.unlock()
                    break
                }
                
                let idx: Int
                let ts = CMSampleBufferGetPresentationTimeStamp(sb)
                condition.lock()
                idx = readFrameIndex
                readFrameIndex += 1
                if firstTimestamp == nil {
                    firstTimestamp = ts
                    self.logInfo("首帧时间戳=\(String(format: "%.3f", CMTimeGetSeconds(ts)))s")
                }
                condition.unlock()
                
                readCount += 1
                
                autoreleasepool {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sb) else {
                        self.logError("[#\(idx)] CMSampleBufferGetImageBuffer 返回 nil")
                        bufferFailedCount += 1
                        return
                    }
                    
                    var ciImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: preferredTransform)
                    let origin = ciImage.extent.origin
                    if origin.x != 0 || origin.y != 0 {
                        ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
                    }
                    guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                        self.logError("[#\(idx)] createCGImage 返回 nil, extent=\(ciImage.extent)")
                        bufferFailedCount += 1
                        return
                    }
                    
                    // 桥接 async（避免 DispatchGroup.wait 死锁）
                    var result: CGImage?
                    let sem = DispatchSemaphore(value: 0)
                    Task.detached(priority: .userInitiated) {
                        do {
                            result = try await SuperResolver.shared.fastUpscale(image: cgImage, modelID: modelID)
                        } catch {
                            self.logError("[#\(idx)] 超分失败: \(error.localizedDescription)")
                        }
                        sem.signal()
                    }
                    sem.wait()
                    
                    guard let resImage = result else {
                        srFailedCount += 1
                        return
                    }
                    
                    guard let buffer = self.makePixelBuffer(pool: adaptor.pixelBufferPool,
                                                            image: resImage,
                                                            width: targetWidth,
                                                            height: targetHeight) else {
                        self.logError("[#\(idx)] makePixelBuffer 失败 pool=\(adaptor.pixelBufferPool == nil ? "nil" : "ok")")
                        bufferFailedCount += 1
                        return
                    }
                    
                    condition.lock()
                    completedBuffers[idx]    = buffer
                    completedTimestamps[idx] = ts
                    condition.broadcast()
                    condition.unlock()
                }
            }
            
            self.logInfo("⏹ Producer 结束: 读取=\(readCount) 抽帧跳过=\(skippedCount) 超分失败=\(srFailedCount) buffer失败=\(bufferFailedCount)")
        }
        
        // ---------- Writer + 等待完成 ----------
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resume = ResumeBox()
            
            writer.startSession(atSourceTime: .zero)
            self.logInfo("🎞 startSession(.zero) 完成, writer.status=\(writer.status.rawValue)")
            
            // 唯一一次 requestMediaDataWhenReady（视频）
            let writerQueue = DispatchQueue(label: "video.writer", qos: .userInitiated)
            writerVideoInput.requestMediaDataWhenReady(on: writerQueue) { [weak self] in
                guard let self else { return }
                
                var appendedCount = 0
                var lastLoggedPercent = -1
                
                while writerVideoInput.isReadyForMoreMediaData {
                    condition.lock()
                    
                    // 取消
                    if self.isCancelled {
                        condition.unlock()
                        self.logInfo("🛑 Writer 检测到取消, writer.status=\(writer.status.rawValue)")
                        reader.cancelReading()
                        writer.cancelWriting()
                        resume.once {
                            cont.resume(throwing: NSError(domain: "VideoSR", code: 499,
                                                          userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        }
                        return
                    }
                    
                    // writer 已失败 —— 立刻退出，避免继续 append 崩溃
                    if writer.status == .failed {
                        condition.unlock()
                        let err = writer.error ?? NSError(domain: "VideoSR", code: 500)
                        self.logError("writer.status=.failed error=\(String(describing: err))")
                        reader.cancelReading()
                        resume.once { cont.resume(throwing: err) }
                        return
                    }
                    
                    if let buffer = completedBuffers.removeValue(forKey: writeFrameIndex) {
                        let ts = completedTimestamps.removeValue(forKey: writeFrameIndex) ?? .zero
                        let idx = writeFrameIndex
                        writeFrameIndex += 1
                        condition.unlock()
                        
                        if !adaptor.append(buffer, withPresentationTime: ts) {
                            let err = writer.error ?? NSError(domain: "VideoSR", code: 500)
                            self.logError("[#\(idx)] adaptor.append 失败 ts=\(String(format: "%.3f", CMTimeGetSeconds(ts)))s writer.status=\(writer.status.rawValue) error=\(String(describing: err))")
                            reader.cancelReading()
                            writer.cancelWriting()
                            resume.once { cont.resume(throwing: err) }
                            return
                        }
                        
                        appendedCount += 1
                        let progress = min(1.0, Double(writeFrameIndex) / Double(totalOutputFrames))
                        let pct = Int(progress * 100)
                        if pct / 10 != lastLoggedPercent / 10 {   // 每 10% 打一次，防刷屏
                            lastLoggedPercent = pct
                            self.logInfo("📊 进度 \(pct)% (\(writeFrameIndex)/\(totalOutputFrames))")
                        }
                        DispatchQueue.main.async { progressHandler(progress) }
                        
                    } else if isReadingFinished && readFrameIndex == writeFrameIndex {
                        // 完成
                        condition.unlock()
                        self.logInfo("🏁 数据写入完毕, 共 append=\(appendedCount) 帧, 开始 finishWriting")
                        writerVideoInput.markAsFinished()
                        writerAudioInput?.markAsFinished()
                        writer.finishWriting {
                            self.logInfo("finishWriting 回调 writer.status=\(writer.status.rawValue) error=\(String(describing: writer.error))")
                            if writer.status == .completed {
                                resume.once { cont.resume() }
                            } else {
                                let err = writer.error ?? NSError(domain: "VideoSR", code: 501)
                                resume.once { cont.resume(throwing: err) }
                            }
                        }
                        return
                        
                    } else {
                        // 等待下一帧
                        self.logInfo("⏳ Writer 等待数据: 已有缓存=\(completedBuffers.count) read=\(readFrameIndex) write=\(writeFrameIndex)")
                        condition.wait()
                        condition.unlock()
                        continue
                    }
                }
            }
            
            // 唯一一次 requestMediaDataWhenReady（音频，独立队列）
            if let audioInput = writerAudioInput, let audioOutput = readerAudioOutput {
                let audioQueue = DispatchQueue(label: "audio.writer", qos: .userInitiated)
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    var audioCount = 0
                    while audioInput.isReadyForMoreMediaData {
                        guard let sb = audioOutput.copyNextSampleBuffer() else {
                            Task { @MainActor in
                                AppLogger.shared.log("[视频管道] 🔊 音频读取结束 audioCount=\(audioCount)", isError: false)
                            }
                            audioInput.markAsFinished()
                            return
                        }
                        if !audioInput.append(sb) {
                            Task { @MainActor in
                                AppLogger.shared.log("[视频管道] ❌ 音频 append 失败", isError: true)
                            }
                            audioInput.markAsFinished()
                            return
                        }
                        audioCount += 1
                    }
                }
                self.logInfo("🔊 音频写入任务已注册")
            }
        }
        
        logInfo("✅ 并发超分处理完成！")
    }
    
    // MARK: - Pixel Buffer 复用
    private func makePixelBuffer(pool: CVPixelBufferPool?,
                                 image: CGImage,
                                 width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                                kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary,
                                &pb)
        }
        guard let buffer = pb else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}

// MARK: - NSLock 便捷
extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () throws -> T) rethrows -> T {
        lock(); defer { unlock() }
        return try body()
    }
}