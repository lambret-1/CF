// SuperResApp/Features/video/VideoSuperResProcessor.swift

import Foundation
import AVFoundation
import CoreImage
import UIKit

final class VideoSuperResProcessor: @unchecked Sendable {

    private let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    private let cancelLock = NSLock()
    private var _cancelRequested = false
    private var isCancelRequested: Bool {
        get { cancelLock.withLock { _cancelRequested } }
        set { cancelLock.withLock { _cancelRequested = newValue } }
    }

    func cancel() {
        isCancelRequested = true
    }

    // MARK: - Logging
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

    private func logInfoAsync(_ msg: String) async {
        await MainActor.run {
            AppLogger.shared.log("[视频管道] \(msg)", isError: false)
        }
    }

    // MARK: - Sendable Containers
    private final class PipelineState: @unchecked Sendable {
        let condition = NSCondition()
        var readFrameIndex = 0
        var writeFrameIndex = 0
        var completedBuffers: [Int: CVPixelBuffer] = [:]
        var completedTimestamps: [Int: CMTime] = [:]
        var isReadingFinished = false
        var firstTimestamp: CMTime?
        var readCount = 0
        var skippedCount = 0
        var srFailedCount = 0
        var bufferFailedCount = 0
        var appendedCount = 0
        var audioCount = 0
    }

    private final class PipelineIO: @unchecked Sendable {
        let reader: AVAssetReader
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let videoOutput: AVAssetReaderTrackOutput
        let audioOutput: AVAssetReaderTrackOutput?
        let targetWidth: Int
        let targetHeight: Int
        let preferredTransform: CGAffineTransform
        let skipInterval: Int
        let totalOutputFrames: Int
        let modelID: String

        init(reader: AVAssetReader, writer: AVAssetWriter,
             videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?,
             adaptor: AVAssetWriterInputPixelBufferAdaptor,
             videoOutput: AVAssetReaderTrackOutput, audioOutput: AVAssetReaderTrackOutput?,
             targetWidth: Int, targetHeight: Int,
             preferredTransform: CGAffineTransform, skipInterval: Int,
             totalOutputFrames: Int, modelID: String) {
            self.reader = reader
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            self.videoOutput = videoOutput
            self.audioOutput = audioOutput
            self.targetWidth = targetWidth
            self.targetHeight = targetHeight
            self.preferredTransform = preferredTransform
            self.skipInterval = skipInterval
            self.totalOutputFrames = totalOutputFrames
            self.modelID = modelID
        }
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T

        init(_ initial: T) {
            self.value = initial
        }

        func set(_ v: T) {
            lock.lock()
            value = v
            lock.unlock()
        }

        func get() -> T {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false

        func once(_ action: () -> Void) {
            lock.lock()
            defer { lock.unlock() }
            guard !done else { return }
            done = true
            action()
        }
    }

    // MARK: - Main Process
    func processVideo(
        inputURL: URL,
        outputURL: URL,
        modelID: String,
        scaleFactor: Int,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {

        isCancelRequested = false
        logInfo("==== 开始超分任务 ====")
        logInfo("input=\(inputURL.lastPathComponent) model=\(modelID) scale=\(scaleFactor)x")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
            logInfo("已清理旧输出文件")
        }

        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            logError("找不到视频轨道")
            throw NSError(domain: "VideoSR", code: 404, userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }
        let audioTrack = try? await asset.loadTracks(withMediaType: .audio).first

        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let duration = try await asset.load(.duration)
        let nominalFrameRate = Double(try await videoTrack.load(.nominalFrameRate))

        logInfo("源尺寸=\(naturalSize) transform=\(preferredTransform)")
        logInfo("时长=\(String(format: "%.2f", CMTimeGetSeconds(duration)))s 原帧率=\(String(format: "%.2f", nominalFrameRate))fps")

        let transformedSize = naturalSize.applying(preferredTransform)
        var targetWidth = Int(abs(transformedSize.width)) * scaleFactor
        var targetHeight = Int(abs(transformedSize.height)) * scaleFactor
        targetWidth = (targetWidth / 2) * 2
        targetHeight = (targetHeight / 2) * 2

        let targetMaxFPS: Double = 30.0
        var skipInterval = 1
        if nominalFrameRate > targetMaxFPS {
            skipInterval = max(1, Int(round(nominalFrameRate / targetMaxFPS)))
        }
        logInfo("🎬 目标尺寸=\(targetWidth)x\(targetHeight) 抽帧间隔=\(skipInterval)")

        // Reader
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
            logInfo("🔊 已找到音频轨道")
        } else {
            logInfo("🔇 无音频轨道")
        }

        // Writer
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
        
        logInfo("⚙️ reader/writer 启动成功 reader.status=\(reader.status.rawValue) writer.status=\(writer.status.rawValue)")

        writer.startSession(atSourceTime: .zero)
        logInfo("🎞 startSession(.zero) 完成")

        let totalOutputFrames = max(1, Int(CMTimeGetSeconds(duration) * nominalFrameRate) / skipInterval)
        logInfo("预计输出帧数=\(totalOutputFrames)")

        let io = PipelineIO(
            reader: reader, writer: writer,
            videoInput: writerVideoInput, audioInput: writerAudioInput,
            adaptor: adaptor, videoOutput: readerVideoOutput, audioOutput: readerAudioOutput,
            targetWidth: targetWidth, targetHeight: targetHeight,
            preferredTransform: preferredTransform,
            skipInterval: skipInterval,
            totalOutputFrames: totalOutputFrames,
            modelID: modelID
        )

        let state = PipelineState()
        let processor = self
        let inFlightLimit = 2

        // Producer
        let producerQueue = DispatchQueue(label: "video.producer", qos: .userInitiated)
        producerQueue.async {
            processor.logInfo("▶️ Producer 启动（并行超分，在途上限=\(inFlightLimit)）")
            var framesToSkip = 0

            while true {
                if processor.isCancelRequested {
                    processor.logInfo("🛑 Producer 检测到取消")
                    break
                }

                state.condition.lock()
                while state.readFrameIndex - state.writeFrameIndex >= inFlightLimit && !processor.isCancelRequested {
                    _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                }
                let cancelNow = processor.isCancelRequested
                state.condition.unlock()
                if cancelNow { break }

                if framesToSkip > 0 {
                    framesToSkip -= 1
                    _ = io.videoOutput.copyNextSampleBuffer()
                    state.condition.lock()
                    state.skippedCount += 1
                    state.condition.unlock()
                    continue
                }
                framesToSkip = io.skipInterval - 1

                guard let sb = io.videoOutput.copyNextSampleBuffer() else {
                    processor.logInfo("📭 Reader 读取结束 reader.status=\(io.reader.status.rawValue) error=\(String(describing: io.reader.error))")
                    state.condition.lock()
                    state.isReadingFinished = true
                    state.condition.broadcast()
                    state.condition.unlock()
                    break
                }

                let idx: Int
                let ts = CMSampleBufferGetPresentationTimeStamp(sb)
                state.condition.lock()
                idx = state.readFrameIndex
                state.readFrameIndex += 1
                state.readCount += 1
                if state.firstTimestamp == nil {
                    state.firstTimestamp = ts
                    processor.logInfo("首帧时间戳=\(String(format: "%.3f", CMTimeGetSeconds(ts)))s")
                }
                state.condition.unlock()

                autoreleasepool {
                    guard let imageBuffer = CMSampleBufferGetImageBuffer(sb) else {
                        processor.logError("[#\(idx)] CMSampleBufferGetImageBuffer 返回 nil")
                        state.condition.lock()
                        state.bufferFailedCount += 1
                        state.condition.unlock()
                        return
                    }

                    var ciImage = CIImage(cvPixelBuffer: imageBuffer).transformed(by: io.preferredTransform)
                    let origin = ciImage.extent.origin
                    if origin.x != 0 || origin.y != 0 {
                        ciImage = ciImage.transformed(by: CGAffineTransform(translationX: -origin.x, y: -origin.y))
                    }
                    guard let cgImage = processor.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                        processor.logError("[#\(idx)] createCGImage 返回 nil")
                        state.condition.lock()
                        state.bufferFailedCount += 1
                        state.condition.unlock()
                        return
                    }

                    let imageBox = LockedBox<CGImage>(cgImage)
                    
                    Task.detached(priority: .userInitiated) { [weak state] in
                        guard let state = state else { return }
                        if processor.isCancelRequested { return }

                        var resImage: CGImage?
                        do {
                            resImage = try await SuperResolver.shared.fastUpscale(image: imageBox.get(), modelID: io.modelID)
                        } catch {
                            let desc = error.localizedDescription
                            Task { @MainActor in
                                AppLogger.shared.log("[视频管道] ❌ [#\(idx)] 超分失败: \(desc)", isError: true)
                            }
                        }

                        guard let resImage = resImage else {
                            state.condition.lock()
                            state.srFailedCount += 1
                            state.condition.broadcast()
                            state.condition.unlock()
                            return
                        }

                        autoreleasepool {
                            guard let buffer = processor.makePixelBuffer(pool: io.adaptor.pixelBufferPool, image: resImage, width: io.targetWidth, height: io.targetHeight) else {
                                state.condition.lock()
                                state.bufferFailedCount += 1
                                state.condition.broadcast()
                                state.condition.unlock()
                                return
                            }

                            state.condition.lock()
                            state.completedBuffers[idx] = buffer
                            state.completedTimestamps[idx] = ts
                            state.condition.broadcast()
                            state.condition.unlock()
                        }
                    }
                }
            }

            state.condition.lock()
            let summary = "⏹ Producer 循环退出: 读取=\(state.readCount) 抽帧跳过=\(state.skippedCount) (超分任务异步提交完毕)"
            state.condition.unlock()
            processor.logInfo(summary)
        }

        // Consumer / Writer
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resume = ResumeBox()

            let writerQueue = DispatchQueue(label: "video.writer", qos: .userInitiated)
            io.videoInput.requestMediaDataWhenReady(on: writerQueue) {
                var lastLoggedPercent = -100
                var lastWaitLog = Date.distantPast

                while io.videoInput.isReadyForMoreMediaData {
                    state.condition.lock()

                    if processor.isCancelRequested {
                        state.condition.unlock()
                        processor.logInfo("🛑 Writer 检测到取消, writer.status=\(io.writer.status.rawValue)")
                        io.reader.cancelReading()
                        io.writer.cancelWriting()
                        resume.once {
                            cont.resume(throwing: NSError(domain: "VideoSR", code: 499, userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        }
                        return
                    }

                    if io.writer.status == .failed {
                        state.condition.unlock()
                        let err = io.writer.error ?? NSError(domain: "VideoSR", code: 500)
                        processor.logError("writer.status=.failed error=\(String(describing: err))")
                        io.reader.cancelReading()
                        resume.once { cont.resume(throwing: err) }
                        return
                    }

                    if let buffer = state.completedBuffers.removeValue(forKey: state.writeFrameIndex) {
                        let ts = state.completedTimestamps.removeValue(forKey: state.writeFrameIndex) ?? .zero
                        let idx = state.writeFrameIndex
                        state.writeFrameIndex += 1
                        let inFlight = state.readFrameIndex - state.writeFrameIndex
                        state.condition.unlock()

                        if !io.adaptor.append(buffer, withPresentationTime: ts) {
                            let err = io.writer.error ?? NSError(domain: "VideoSR", code: 500)
                            processor.logError("[#\(idx)] adaptor.append 失败 ts=\(String(format: "%.3f", CMTimeGetSeconds(ts)))s writer.status=\(io.writer.status.rawValue) error=\(String(describing: err))")
                            io.reader.cancelReading()
                            io.writer.cancelWriting()
                            resume.once { cont.resume(throwing: err) }
                            return
                        }

                        state.condition.lock()
                        state.appendedCount += 1
                        let done = state.writeFrameIndex
                        let cacheSize = state.completedBuffers.count
                        state.condition.unlock()

                        let progress = min(1.0, Double(done) / Double(io.totalOutputFrames))
                        let pct = Int(progress * 100)
                        
                        if pct / 10 != lastLoggedPercent / 10 {
                            lastLoggedPercent = pct
                            processor.logInfo("📊 进度 \(pct)% (\(done)/\(io.totalOutputFrames)) 在途=\(inFlight) 缓存=\(cacheSize)")
                        }
                        
                        let p = progress
                        Task { @MainActor in progressHandler(p) }

                    } else if state.isReadingFinished && state.readFrameIndex == state.writeFrameIndex {
                        let finalCount = state.appendedCount
                        state.condition.unlock()
                        processor.logInfo("🏁 数据写入完毕 共 append=\(finalCount) 帧, 开始 finishWriting")
                        io.videoInput.markAsFinished()
                        io.audioInput?.markAsFinished()
                        io.writer.finishWriting {
                            processor.logInfo("finishWriting 回调 writer.status=\(io.writer.status.rawValue) error=\(String(describing: io.writer.error))")
                            if io.writer.status == .completed {
                                resume.once { cont.resume() }
                            } else {
                                let err = io.writer.error ?? NSError(domain: "VideoSR", code: 501)
                                resume.once { cont.resume(throwing: err) }
                            }
                        }
                        return

                    } else {
                        let now = Date()
                        if now.timeIntervalSince(lastWaitLog) >= 5.0 {
                            lastWaitLog = now
                            processor.logInfo("⏳ Writer 等待: 缓存=\(state.completedBuffers.count) read=\(state.readFrameIndex) write=\(state.writeFrameIndex)")
                        }
                        _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                        state.condition.unlock()
                        continue
                    }
                }
            }

            // Audio
            if let audioInput = io.audioInput, let audioOutput = io.audioOutput {
                let audioQueue = DispatchQueue(label: "audio.writer", qos: .userInitiated)
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let sb = audioOutput.copyNextSampleBuffer() else {
                            let count = state.audioCount
                            processor.logInfo("🔊 音频读取结束 audioCount=\(count)")
                            audioInput.markAsFinished()
                            return
                        }
                        if !audioInput.append(sb) {
                            processor.logError("音频 append 失败")
                            audioInput.markAsFinished()
                            return
                        }
                        state.condition.lock()
                        state.audioCount += 1
                        state.condition.unlock()
                    }
                }
                processor.logInfo("🔊 音频写入任务已注册")
            }
        }

        state.condition.lock()
        let finalMsg = "✅ 完成: 读取=\(state.readCount) 跳过=\(state.skippedCount) 超分失败=\(state.srFailedCount) buffer失败=\(state.bufferFailedCount) 视频append=\(state.appendedCount) 音频=\(state.audioCount)"
        state.condition.unlock()
        await logInfoAsync(finalMsg)
    }

      private func makePixelBuffer(pool: CVPixelBufferPool?, image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        }
        
        guard let buffer = pb else { return nil }

        // ⭐️ 优化点：使用 CIContext 的 GPU 渲染，替代 CPU 密集的 CGContext.draw
        let ciImage = CIImage(cgImage: image)
        // 确保渲染的比例和尺寸完全匹配
        let scaleX = CGFloat(width) / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        // 直接渲染到 CVPixelBuffer，速度极快
        ciContext.render(scaledImage, to: buffer)
        
        return buffer
    }
    }