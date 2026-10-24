// SuperResApp/Features/video/VideoSuperResProcessor.swift

import Foundation
import AVFoundation
import CoreImage
import CoreVideo

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

    /// 让 producer Task 能够被取消（进而触发 AsyncThrowingStream.onCancel → reader.cancelReading）
    private let producerTaskBox = LockedBox<Task<Void, Never>?>(nil)

    func cancel() {
        isCancelRequested = true
        producerTaskBox.get()?.cancel()
    }

    // MARK: - Logging
    private func logInfo(_ msg: String) {
        Task { @MainActor in AppLogger.shared.log("[视频管道] \(msg)", isError: false) }
    }
    private func logError(_ msg: String) {
        Task { @MainActor in AppLogger.shared.log("[视频管道] ❌ \(msg)", isError: true) }
    }
    private func logInfoAsync(_ msg: String) async {
        await MainActor.run { AppLogger.shared.log("[视频管道] \(msg)", isError: false) }
    }

    private static func formatDuration(_ d: Duration) -> String {
        let c = d.components
        let total = Double(c.seconds) + Double(c.attoseconds) / 1e18
        if total >= 3600 {
            return String(format: "%d小时%02d分%05.2f秒",
                          Int(total) / 3600, (Int(total) % 3600) / 60,
                          total.truncatingRemainder(dividingBy: 60))
        }
        if total >= 60 {
            return String(format: "%d分%.2f秒",
                          Int(total) / 60, total.truncatingRemainder(dividingBy: 60))
        }
        return String(format: "%.2f秒", total)
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
        let writer: AVAssetWriter
        let videoInput: AVAssetWriterInput
        let audioInput: AVAssetWriterInput?
        let adaptor: AVAssetWriterInputPixelBufferAdaptor
        let audioReader: AVAssetReader?
        let audioOutput: AVAssetReaderTrackOutput?
        let targetWidth: Int
        let targetHeight: Int
        let skipInterval: Int
        let totalOutputFrames: Int
        let modelID: String

        init(writer: AVAssetWriter,
             videoInput: AVAssetWriterInput, audioInput: AVAssetWriterInput?,
             adaptor: AVAssetWriterInputPixelBufferAdaptor,
             audioReader: AVAssetReader?, audioOutput: AVAssetReaderTrackOutput?,
             targetWidth: Int, targetHeight: Int,
             skipInterval: Int, totalOutputFrames: Int, modelID: String) {
            self.writer = writer
            self.videoInput = videoInput
            self.audioInput = audioInput
            self.adaptor = adaptor
            self.audioReader = audioReader
            self.audioOutput = audioOutput
            self.targetWidth = targetWidth
            self.targetHeight = targetHeight
            self.skipInterval = skipInterval
            self.totalOutputFrames = totalOutputFrames
            self.modelID = modelID
        }
    }

    private final class LockedBox<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var value: T
        init(_ initial: T) { self.value = initial }
        func set(_ v: T) { lock.lock(); value = v; lock.unlock() }
        func get() -> T { lock.lock(); defer { lock.unlock() }; return value }
    }

    private final class ResumeBox: @unchecked Sendable {
        private let lock = NSLock()
        private var done = false
        func once(_ action: () -> Void) {
            lock.lock(); defer { lock.unlock() }
            guard !done else { return }
            done = true
            action()
        }
    }

    // MARK: - Main Process

    /// 接收 `VideoDownscaler.open()` 的帧流，做 4x 超分并写出目标文件。
    /// - Parameters:
    ///   - source: 降采样产物（含 metadata + frames）
    ///   - audioSourceURL: 原始视频路径（用于 pass-through 音频）
    ///   - outputURL: 最终输出路径（.mov）
    ///   - modelID: SuperResolver 的模型标识
    ///   - scaleFactor: 超分倍数（默认 4，用于推导输出尺寸）
    ///   - targetOutputSize: 若指定，超分结果会缩放到该尺寸；nil = 保持 `targetSize*scaleFactor`
    func processVideo(
        source: VideoDownscaler.Output,
        audioSourceURL: URL,
        outputURL: URL,
        modelID: String,
        scaleFactor: Int = 4,
        targetOutputSize: CGSize? = nil,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {

        let clock = ContinuousClock()
        let startInstant = clock.now
        let finalAppendedCountBox = LockedBox<Int>(0)
        defer {
            let elapsed = clock.now - startInstant
            let totalSecs = Double(elapsed.components.seconds) + Double(elapsed.components.attoseconds) / 1e18
            let count = finalAppendedCountBox.get()
            var avgMsg = ""
            if count > 0 {
                let avg = totalSecs / Double(count)
                avgMsg = " 平均每帧耗时=\(String(format: "%.2f", avg))秒"
            }
            logInfo("==== 任务结束 总用时 \(Self.formatDuration(elapsed))\(avgMsg) ====")
        }

        isCancelRequested = false
        logInfo("==== 开始超分任务 ====")
        logInfo("model=\(modelID) scale=\(scaleFactor)x srcShortSide=\(Int(source.metadata.targetSize.width))x\(Int(source.metadata.targetSize.height))")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try? FileManager.default.removeItem(at: outputURL)
            logInfo("已清理旧输出文件")
        }

        // ── 尺寸 ──────────────────────────────────────────────
        let fps: Double = source.metadata.nominalFrameRate > 0
            ? Double(source.metadata.nominalFrameRate) : 30.0
        let duration = source.metadata.duration
        logInfo("时长=\(String(format: "%.2f", duration.seconds))s 原帧率=\(String(format: "%.2f", fps))fps")

        let scale = max(1, scaleFactor)
        var targetWidth  = Int(source.metadata.targetSize.width)  * scale
        var targetHeight = Int(source.metadata.targetSize.height) * scale
        if let custom = targetOutputSize {
            targetWidth  = Int(custom.width.rounded())
            targetHeight = Int(custom.height.rounded())
        }
        targetWidth  = (targetWidth  / 2) * 2
        targetHeight = (targetHeight / 2) * 2

        let targetMaxFPS: Double = 30.0
        var skipInterval = 1
        if fps > targetMaxFPS {
            skipInterval = max(1, Int(round(fps / targetMaxFPS)))
        }
        logInfo("🎬 目标尺寸=\(targetWidth)x\(targetHeight) 抽帧间隔=\(skipInterval)")

        // ── Writer ────────────────────────────────────────────
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)

        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2
            ],
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: Int(Double(targetWidth * targetHeight) * 8.0),
                AVVideoMaxKeyFrameIntervalKey: 60,
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
                kCVPixelBufferIOSurfacePropertiesKey as String: [:],
                kCVPixelBufferMetalCompatibilityKey as String: true
            ]
        )

        // ── 音频 pass-through ──────────────────────────────────
        var audioReader: AVAssetReader?
        var audioReaderOutput: AVAssetReaderTrackOutput?
        var writerAudioInput: AVAssetWriterInput?

        let audioAsset = AVURLAsset(url: audioSourceURL)
        if let audioTrack = try? await audioAsset.loadTracks(withMediaType: .audio).first,
           let r = try? AVAssetReader(asset: audioAsset) {
            let ro = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil) // 不解码
            if r.canAdd(ro) {
                r.add(ro)
                let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil) // 不重编码
                ai.expectsMediaDataInRealTime = false
                if writer.canAdd(ai) {
                    writer.add(ai)
                    audioReader = r
                    audioReaderOutput = ro
                    writerAudioInput = ai
                    logInfo("🔊 音频 pass-through 已启用")
                }
            }
        }
        if writerAudioInput == nil { logInfo("🔇 无音频轨道或不可直通") }

        // ── 启动 ────────────────────────────────────────────────
        guard writer.startWriting() else {
            logError("writer.startWriting 失败: \(String(describing: writer.error))")
            throw writer.error ?? NSError(domain: "VideoSR", code: -2)
        }
        logInfo("⚙️ writer 启动成功 status=\(writer.status.rawValue)")

        writer.startSession(atSourceTime: .zero)

        if let r = audioReader, !r.startReading() {
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw r.error ?? NSError(domain: "VideoSR", code: -3, userInfo: [NSLocalizedDescriptionKey: "音频 reader 启动失败"])
        }

        let totalOutputFrames = max(1, Int(duration.seconds * fps) / skipInterval)
        logInfo("预计输出帧数=\(totalOutputFrames)")

        let io = PipelineIO(
            writer: writer,
            videoInput: writerVideoInput, audioInput: writerAudioInput,
            adaptor: adaptor,
            audioReader: audioReader, audioOutput: audioReaderOutput,
            targetWidth: targetWidth, targetHeight: targetHeight,
            skipInterval: skipInterval,
            totalOutputFrames: totalOutputFrames,
            modelID: modelID
        )

        let state = PipelineState()
        let processor = self
        let inFlightLimit = 3

        // ── Producer：消费帧流 ────────────────────────────────
        let producerTask = Task.detached(priority: .userInitiated) { [weak state] in
            guard let state = state else { return }
            processor.logInfo("▶️ Producer 启动（帧流模式，在途上限=\(inFlightLimit)）")
            var framesToSkip = 0

            defer {
                state.condition.lock()
                state.isReadingFinished = true
                state.condition.broadcast()
                state.condition.unlock()
                processor.logInfo("⏹ Producer 退出 readCount=\(state.readCount) skipped=\(state.skippedCount)")
            }

            do {
                for try await frame in source.frames {
                    if processor.isCancelRequested || Task.isCancelled { break }

                    // 抽帧
                    if framesToSkip > 0 {
                        framesToSkip -= 1
                        state.condition.lock(); state.skippedCount += 1; state.condition.unlock()
                        continue
                    }
                    framesToSkip = io.skipInterval - 1

                    // 背压：等待在途槽位
                    state.condition.lock()
                    while state.readFrameIndex - state.writeFrameIndex >= inFlightLimit && !processor.isCancelRequested {
                        _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.05))
                    }
                    let cancelNow = processor.isCancelRequested
                    state.condition.unlock()
                    if cancelNow { break }

                    let idx: Int
                    let ts = frame.presentationTime
                    state.condition.lock()
                    idx = state.readFrameIndex
                    state.readFrameIndex += 1
                    state.readCount += 1
                    if state.firstTimestamp == nil {
                        state.firstTimestamp = ts
                        processor.logInfo("首帧 PTS=\(String(format: "%.3f", ts.seconds))s")
                    }
                    state.condition.unlock()

                    autoreleasepool {
                        // downscaler 已修正旋转/缩放，这里只需转 CGImage
                        let ciImage = CIImage(cvPixelBuffer: frame.pixelBuffer)
                        guard let cgImage = processor.ciContext.createCGImage(ciImage, from: ciImage.extent) else {
                            processor.logError("[#\(idx)] createCGImage 返回 nil")
                            state.condition.lock(); state.bufferFailedCount += 1; state.condition.unlock()
                            return
                        }
                        let imageBox = LockedBox<CGImage>(cgImage)

                        Task.detached(priority: .userInitiated) { [weak state] in
                            guard let state = state else { return }
                            if processor.isCancelRequested { return }

                            var resImage: CGImage?
                            do {
                                let srStart = ContinuousClock.now
                                resImage = try await SuperResolver.shared.fastUpscale(image: imageBox.get(), modelID: io.modelID)
                                let cost = ContinuousClock.now - srStart
                                processor.logInfo("[#\(idx)] 超分耗时=\(Self.formatDuration(cost))")
                            } catch {
                                let desc = error.localizedDescription
                                Task { @MainActor in
                                    AppLogger.shared.log("[视频管道] ❌ [#\(idx)] 超分失败: \(desc)", isError: true)
                                }
                            }

                            guard let resImage = resImage else {
                                state.condition.lock(); state.srFailedCount += 1
                                state.condition.broadcast(); state.condition.unlock()
                                return
                            }

                            autoreleasepool {
                                guard let buffer = processor.makePixelBuffer(
                                    pool: io.adaptor.pixelBufferPool,
                                    image: resImage,
                                    width: io.targetWidth, height: io.targetHeight
                                ) else {
                                    state.condition.lock(); state.bufferFailedCount += 1
                                    state.condition.broadcast(); state.condition.unlock()
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
            } catch is CancellationError {
                processor.logInfo("🛑 Producer 被取消")
            } catch {
                processor.logError("Producer 异常: \(error.localizedDescription)")
            }
        }
        producerTaskBox.set(producerTask)

        // ── Writer + Audio ────────────────────────────────────
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            let resume = ResumeBox()
            let writerQueue = DispatchQueue(label: "video.writer", qos: .userInitiated)
            let logState = LockedBox<(percent: Int, wait: Date)>((-100, Date.distantPast))

            io.videoInput.requestMediaDataWhenReady(on: writerQueue) {
                while io.videoInput.isReadyForMoreMediaData {
                    state.condition.lock()

                    if processor.isCancelRequested {
                        state.condition.unlock()
                        processor.logInfo("🛑 Writer 检测到取消 writer.status=\(io.writer.status.rawValue)")
                        io.writer.cancelWriting()
                        io.audioReader?.cancelReading()
                        resume.once {
                            cont.resume(throwing: NSError(domain: "VideoSR", code: 499,
                                                          userInfo: [NSLocalizedDescriptionKey: "用户已取消"]))
                        }
                        return
                    }

                    if io.writer.status == .failed {
                        state.condition.unlock()
                        let err = io.writer.error ?? NSError(domain: "VideoSR", code: 500)
                        processor.logError("writer.status=.failed \(String(describing: err))")
                        io.audioReader?.cancelReading()
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
                            processor.logError("[#\(idx)] adaptor.append 失败 ts=\(String(format: "%.3f", ts.seconds))s \(String(describing: err))")
                            io.writer.cancelWriting()
                            io.audioReader?.cancelReading()
                            resume.once { cont.resume(throwing: err) }
                            return
                        }

                        state.condition.lock()
                        state.appendedCount += 1
                        let done = state.writeFrameIndex
                        let cacheSize = state.completedBuffers.count
                        finalAppendedCountBox.set(state.appendedCount)
                        state.condition.unlock()

                        let progress = min(1.0, Double(done) / Double(io.totalOutputFrames))
                        let pct = Int(progress * 100)

                        let cur = logState.get()
                        if pct / 10 != cur.percent / 10 {
                            logState.set((pct, cur.wait))
                            processor.logInfo("📊 进度 \(pct)% (\(done)/\(io.totalOutputFrames)) 在途=\(inFlight) 缓存=\(cacheSize)")
                        }
                        let p = progress
                        Task { @MainActor in progressHandler(p) }

                    } else if state.isReadingFinished && state.readFrameIndex == state.writeFrameIndex {
                        let finalCount = state.appendedCount
                        state.condition.unlock()
                        processor.logInfo("🏁 数据写入完毕 append=\(finalCount) 帧, 开始 finishWriting")
                        io.videoInput.markAsFinished()
                        io.audioInput?.markAsFinished()
                        io.writer.finishWriting {
                            processor.logInfo("finishWriting 回调 status=\(io.writer.status.rawValue) \(String(describing: io.writer.error))")
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
                        let cur = logState.get()
                        if now.timeIntervalSince(cur.wait) >= 5.0 {
                            logState.set((cur.percent, now))
                            processor.logInfo("⏳ Writer 等待: 缓存=\(state.completedBuffers.count) read=\(state.readFrameIndex) write=\(state.writeFrameIndex)")
                        }
                        _ = state.condition.wait(until: Date(timeIntervalSinceNow: 0.1))
                        state.condition.unlock()
                        continue
                    }
                }
            }

            if let audioInput = io.audioInput, let audioOutput = io.audioOutput {
                let audioQueue = DispatchQueue(label: "audio.writer", qos: .userInitiated)
                audioInput.requestMediaDataWhenReady(on: audioQueue) {
                    while audioInput.isReadyForMoreMediaData {
                        guard let sb = audioOutput.copyNextSampleBuffer() else {
                            processor.logInfo("🔊 音频结束 audioCount=\(state.audioCount)")
                            audioInput.markAsFinished()
                            return
                        }
                        if !audioInput.append(sb) {
                            processor.logError("音频 append 失败")
                            audioInput.markAsFinished()
                            return
                        }
                        state.condition.lock(); state.audioCount += 1; state.condition.unlock()
                    }
                }
                processor.logInfo("🔊 音频写入任务已注册")
            }
        }

        // 正常/异常结束后：确保 producer task 退出
        producerTask.cancel()
        producerTaskBox.set(nil)

        state.condition.lock()
        let finalMsg = "✅ 完成: read=\(state.readCount) skip=\(state.skippedCount) srFail=\(state.srFailedCount) bufFail=\(state.bufferFailedCount) videoAppend=\(state.appendedCount) audio=\(state.audioCount)"
        state.condition.unlock()
        await logInfoAsync(finalMsg)
    }

    // MARK: - CGImage → CVPixelBuffer

    private func makePixelBuffer(pool: CVPixelBufferPool?, image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = pool {
            CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &pb)
        } else {
            CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA,
                                [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &pb)
        }
        guard let buffer = pb else { return nil }

        let ciImage = CIImage(cgImage: image)
        let sx = CGFloat(width)  / ciImage.extent.width
        let sy = CGFloat(height) / ciImage.extent.height
        let scaled = ciImage.transformed(by: CGAffineTransform(scaleX: sx, y: sy))
        ciContext.render(scaled, to: buffer)
        return buffer
    }
}