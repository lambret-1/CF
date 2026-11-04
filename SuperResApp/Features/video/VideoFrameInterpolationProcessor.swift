import Foundation
import AVFoundation
import CoreML
import CoreVideo

/// 独立的 RIFE 视频补帧管线。所有插帧推理严格串行执行，
/// 不复用超分处理器的并行 producer/consumer 队列。
final class VideoFrameInterpolationProcessor: @unchecked Sendable {
    private let cancelLock = NSLock()
    private var cancelled = false

    func cancel() {
        cancelLock.lock()
        cancelled = true
        cancelLock.unlock()
    }

    private var isCancelled: Bool {
        cancelLock.lock()
        defer { cancelLock.unlock() }
        return cancelled
    }

    func processVideo(
        inputURL: URL,
        outputURL: URL,
        multiplier: Int,
        fastMode: Bool = false,
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard multiplier == 2 || multiplier == 4 else {
            throw FrameInterpolationError.unsupportedMultiplier
        }
        cancelLock.withLock { cancelled = false }

        await log("[补帧] 开始处理：倍数 \(multiplier)x，快速模式：\(fastMode ? "开启" : "关闭")")
        let model = try await ModelStore.shared.loadFrameInterpolationModel()
        guard let interpolator = FrameInterpolator(model: model) else {
            await log("[补帧] RIFE 推理器初始化失败", isError: true)
            throw FrameInterpolationError.initializationFailed
        }
        await log("[补帧] RIFE 模型加载成功")

        if FileManager.default.fileExists(atPath: outputURL.path) {
            try FileManager.default.removeItem(at: outputURL)
        }

        let asset = AVURLAsset(url: inputURL)
        guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
            throw FrameInterpolationError.videoTrackNotFound
        }
        let audioTrack = try await asset.loadTracks(withMediaType: .audio).first
        let duration = try await asset.load(.duration)
        let naturalSize = try await videoTrack.load(.naturalSize)
        let preferredTransform = try await videoTrack.load(.preferredTransform)
        let width = max(2, Int(naturalSize.width).quotientAndRemainder(dividingBy: 2).quotient * 2)
        let height = max(2, Int(naturalSize.height).quotientAndRemainder(dividingBy: 2).quotient * 2)
        let nominalFrameRate = Double((try? await videoTrack.load(.nominalFrameRate)) ?? 0)
        let durationSeconds = CMTimeGetSeconds(duration)
        await log("[补帧] 输入视频：\\(width)×\\(height)，\\(String(format: "%.2f", nominalFrameRate))fps，时长 \\(String(format: "%.2f", durationSeconds))s")

        let reader = try AVAssetReader(asset: asset)
        let videoOutput = AVAssetReaderTrackOutput(track: videoTrack, outputSettings: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ])
        videoOutput.alwaysCopiesSampleData = false
        guard reader.canAdd(videoOutput) else { throw FrameInterpolationError.readerConfigurationFailed }
        reader.add(videoOutput)

        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.hevc,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoCompressionPropertiesKey: [
                AVVideoAverageBitRateKey: max(2_000_000, width * height * 4),
                AVVideoMaxKeyFrameIntervalKey: 30
            ]
        ])
        videoInput.expectsMediaDataInRealTime = false
        videoInput.transform = preferredTransform
        guard writer.canAdd(videoInput) else { throw FrameInterpolationError.writerConfigurationFailed }
        writer.add(videoInput)

        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: videoInput,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: width,
                kCVPixelBufferHeightKey as String: height,
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]
        )

        var audioOutput: AVAssetReaderTrackOutput?
        var audioInput: AVAssetWriterInput?
        if let audioTrack {
            let descriptions = try? await audioTrack.load(.formatDescriptions)
            let input = AVAssetWriterInput(
                mediaType: .audio,
                outputSettings: nil,
                sourceFormatHint: descriptions?.first
            )
            input.expectsMediaDataInRealTime = false
            if writer.canAdd(input) {
                let output = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
                output.alwaysCopiesSampleData = false
                if reader.canAdd(output) {
                    writer.add(input)
                    reader.add(output)
                    audioInput = input
                    audioOutput = output
                }
            }
        }

        guard reader.startReading() else {
            throw reader.error ?? FrameInterpolationError.readerStartFailed
        }
        guard writer.startWriting() else {
            reader.cancelReading()
            throw writer.error ?? FrameInterpolationError.writerStartFailed
        }
        writer.startSession(atSourceTime: .zero)

        // 音频压缩 sample buffer 直接复用原时间戳，不解码重编码。
        let audioTask: Task<Void, Never>? = {
            guard let audioOutput, let audioInput else { return nil }
            return Task.detached {
                while !Task.isCancelled, let sample = audioOutput.copyNextSampleBuffer() {
                    while !audioInput.isReadyForMoreMediaData {
                        if Task.isCancelled || writer.status == .failed { break }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    if Task.isCancelled { break }
                    guard audioInput.append(sample) else { break }
                }
                audioInput.markAsFinished()
            }
        }()

        do {
            guard let firstSample = videoOutput.copyNextSampleBuffer(),
                  let firstBuffer = CMSampleBufferGetImageBuffer(firstSample) else {
                throw FrameInterpolationError.noVideoFrames
            }
            var previousBuffer = firstBuffer
            var previousTime = CMSampleBufferGetPresentationTimeStamp(firstSample)
            var processedFrames = 0
            var aiIntermediateFrames = 0
            var blendedIntermediateFrames = 0
            let estimatedFrames = nominalFrameRate.isFinite && nominalFrameRate > 0 && durationSeconds.isFinite && durationSeconds > 0
                ? max(1, Int((durationSeconds * nominalFrameRate).rounded(.up)))
                : 1

            while let sample = videoOutput.copyNextSampleBuffer() {
                try checkCancellation()
                guard let currentBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let currentTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let delta = CMTimeSubtract(currentTime, previousTime)
                let deltaSeconds = CMTimeGetSeconds(delta)
                guard currentTime.isValid, delta.isValid, deltaSeconds.isFinite, deltaSeconds > 0 else {
                    throw FrameInterpolationError.invalidFrameTimestamp
                }

                try await append(previousBuffer, at: previousTime, adaptor: adaptor, input: videoInput, writer: writer)

                // BZ 原版快速模式：相邻帧平均亮度差 < 8.0 用 50/50 混合，
                // >= 8.0 保留 RIFE AI 插值。4x 的 1/2 中间帧始终先由 RIFE 生成。
                let motion = fastMode ? estimateMotion(frame0: previousBuffer, frame1: currentBuffer) : 255
                let useAI = !fastMode || motion >= 8.0

                if multiplier == 2 {
                    let middle: CVPixelBuffer
                    if useAI {
                        guard let inferred = interpolator.interpolate(frame0: previousBuffer, frame1: currentBuffer) else {
                            throw FrameInterpolationError.inferenceFailed
                        }
                        middle = inferred
                        aiIntermediateFrames += 1
                    } else {
                        middle = blendFrames(previousBuffer, currentBuffer) ?? previousBuffer
                        blendedIntermediateFrames += 1
                    }
                    try checkCancellation()
                    let time = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(delta, multiplier: 1, divisor: 2))
                    try await append(middle, at: time, adaptor: adaptor, input: videoInput, writer: writer)
                } else {
                    guard let middle = interpolator.interpolate(frame0: previousBuffer, frame1: currentBuffer) else {
                        throw FrameInterpolationError.inferenceFailed
                    }
                    aiIntermediateFrames += 1

                    let quarter: CVPixelBuffer
                    let threeQuarter: CVPixelBuffer
                    if useAI {
                        guard let inferredQuarter = interpolator.interpolate(frame0: previousBuffer, frame1: middle),
                              let inferredThreeQuarter = interpolator.interpolate(frame0: middle, frame1: currentBuffer) else {
                            throw FrameInterpolationError.inferenceFailed
                        }
                        quarter = inferredQuarter
                        threeQuarter = inferredThreeQuarter
                        aiIntermediateFrames += 2
                    } else {
                        quarter = blendFrames(previousBuffer, middle) ?? previousBuffer
                        threeQuarter = blendFrames(middle, currentBuffer) ?? currentBuffer
                        blendedIntermediateFrames += 2
                    }

                    try checkCancellation()
                    let quarterTime = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(delta, multiplier: 1, divisor: 4))
                    let middleTime = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(delta, multiplier: 1, divisor: 2))
                    let threeQuarterTime = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(delta, multiplier: 3, divisor: 4))
                    try await append(quarter, at: quarterTime, adaptor: adaptor, input: videoInput, writer: writer)
                    try await append(middle, at: middleTime, adaptor: adaptor, input: videoInput, writer: writer)
                    try await append(threeQuarter, at: threeQuarterTime, adaptor: adaptor, input: videoInput, writer: writer)
                }

                previousBuffer = currentBuffer
                previousTime = currentTime
                processedFrames += 1
                let value = min(0.99, Double(processedFrames) / Double(estimatedFrames))
                await progressHandler(value)
                if processedFrames == 1 || processedFrames % 120 == 0 {
                    await log("[补帧进度] 已读取 \(processedFrames)/\(estimatedFrames) 帧，RIFE 中间帧 \(aiIntermediateFrames)，快速混合帧 \(blendedIntermediateFrames)")
                }
            }

            try checkCancellation()
            try await append(previousBuffer, at: previousTime, adaptor: adaptor, input: videoInput, writer: writer)
            videoInput.markAsFinished()
            await audioTask?.value
            guard reader.status == .completed else {
                throw reader.error ?? FrameInterpolationError.readerStartFailed
            }
            try await finish(writer)
            await progressHandler(1.0)
            await log("[补帧完成] RIFE 中间帧 \(aiIntermediateFrames)，快速混合帧 \(blendedIntermediateFrames)")
        } catch {
            audioTask?.cancel()
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            await log("[补帧失败] \(error.localizedDescription)", isError: true)
            throw error
        }
    }

    // MARK: - BZ 原版快速模式：运动检测与帧混合
    /// 64×64 等距采样相邻帧，计算平均绝对亮度差；阈值沿用 BZ 的 8.0。
    private func estimateMotion(frame0: CVPixelBuffer, frame1: CVPixelBuffer) -> Float {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)
        guard width > 0, height > 0,
              width == CVPixelBufferGetWidth(frame1),
              height == CVPixelBufferGetHeight(frame1) else { return 255 }

        guard CVPixelBufferLockBaseAddress(frame0, .readOnly) == kCVReturnSuccess else { return 255 }
        guard CVPixelBufferLockBaseAddress(frame1, .readOnly) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            return 255
        }
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
        }
        guard let address0 = CVPixelBufferGetBaseAddress(frame0),
              let address1 = CVPixelBufferGetBaseAddress(frame1) else { return 255 }

        let rowBytes0 = CVPixelBufferGetBytesPerRow(frame0)
        let rowBytes1 = CVPixelBufferGetBytesPerRow(frame1)
        let stepX = max(width / 64, 1)
        let stepY = max(height / 64, 1)
        let pixels0 = address0.assumingMemoryBound(to: UInt8.self)
        let pixels1 = address1.assumingMemoryBound(to: UInt8.self)
        var sum: Int64 = 0
        var count: Int64 = 0

        for y in stride(from: 0, to: height, by: stepY) {
            let row0 = pixels0.advanced(by: y * rowBytes0)
            let row1 = pixels1.advanced(by: y * rowBytes1)
            for x in stride(from: 0, to: width, by: stepX) {
                let offset = x * 4
                let b0 = Int(row0[offset]), g0 = Int(row0[offset + 1]), r0 = Int(row0[offset + 2])
                let b1 = Int(row1[offset]), g1 = Int(row1[offset + 1]), r1 = Int(row1[offset + 2])
                let l0 = (r0 * 30 + g0 * 59 + b0 * 11) / 100
                let l1 = (r1 * 30 + g1 * 59 + b1 * 11) / 100
                sum += Int64(abs(l0 - l1))
                count += 1
            }
        }
        return count > 0 ? Float(sum) / Float(count) : 255
    }

    private func blendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
        if let gpuResult = RIFEFrameBlender.shared?.blend(frame0: frame0, frame1: frame1) {
            return gpuResult
        }
        return cpuBlendFrames(frame0, frame1)
    }

    /// BZ 原版 Metal 不可用时的 CPU 50/50 混合回退。
    private func cpuBlendFrames(_ frame0: CVPixelBuffer, _ frame1: CVPixelBuffer) -> CVPixelBuffer? {
        let width = CVPixelBufferGetWidth(frame0)
        let height = CVPixelBufferGetHeight(frame0)
        guard width > 0, height > 0,
              width == CVPixelBufferGetWidth(frame1),
              height == CVPixelBufferGetHeight(frame1) else { return nil }

        let attrs: CFDictionary = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        var outputBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs, &outputBuffer) == kCVReturnSuccess,
              let output = outputBuffer else { return nil }

        guard CVPixelBufferLockBaseAddress(frame0, .readOnly) == kCVReturnSuccess else { return nil }
        guard CVPixelBufferLockBaseAddress(frame1, .readOnly) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            return nil
        }
        guard CVPixelBufferLockBaseAddress(output, []) == kCVReturnSuccess else {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
            return nil
        }
        defer {
            CVPixelBufferUnlockBaseAddress(frame0, .readOnly)
            CVPixelBufferUnlockBaseAddress(frame1, .readOnly)
            CVPixelBufferUnlockBaseAddress(output, [])
        }

        guard let src0 = CVPixelBufferGetBaseAddress(frame0)?.assumingMemoryBound(to: UInt8.self),
              let src1 = CVPixelBufferGetBaseAddress(frame1)?.assumingMemoryBound(to: UInt8.self),
              let dst = CVPixelBufferGetBaseAddress(output)?.assumingMemoryBound(to: UInt8.self) else { return nil }
        let row0Bytes = CVPixelBufferGetBytesPerRow(frame0)
        let row1Bytes = CVPixelBufferGetBytesPerRow(frame1)
        let dstBytes = CVPixelBufferGetBytesPerRow(output)
        for y in 0..<height {
            let row0 = src0.advanced(by: y * row0Bytes)
            let row1 = src1.advanced(by: y * row1Bytes)
            let out = dst.advanced(by: y * dstBytes)
            for x in 0..<(width * 4) {
                out[x] = UInt8((UInt16(row0[x]) + UInt16(row1[x])) / 2)
            }
        }
        return output
    }

    private func log(_ message: String, isError: Bool = false) async {
        await MainActor.run { AppLogger.shared.log(message, isError: isError) }
    }

    // MARK: - 写入辅助
    private func append(
        _ buffer: CVPixelBuffer,
        at time: CMTime,
        adaptor: AVAssetWriterInputPixelBufferAdaptor,
        input: AVAssetWriterInput,
        writer: AVAssetWriter
    ) async throws {
        while !input.isReadyForMoreMediaData {
            try checkCancellation()
            if writer.status == .failed { throw writer.error ?? FrameInterpolationError.writeFailed }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        try checkCancellation()
        guard adaptor.append(buffer, withPresentationTime: time) else {
            throw writer.error ?? FrameInterpolationError.writeFailed
        }
    }

    private func checkCancellation() throws {
        if isCancelled || Task.isCancelled { throw CancellationError() }
    }

    private func finish(_ writer: AVAssetWriter) async throws {
        await withCheckedContinuation { continuation in
            writer.finishWriting { continuation.resume() }
        }
        guard writer.status == .completed else {
            throw writer.error ?? FrameInterpolationError.writeFailed
        }
    }
}

private enum FrameInterpolationError: LocalizedError {
    case unsupportedMultiplier
    case initializationFailed
    case videoTrackNotFound
    case readerConfigurationFailed
    case writerConfigurationFailed
    case readerStartFailed
    case writerStartFailed
    case noVideoFrames
    case invalidFrameTimestamp
    case inferenceFailed
    case writeFailed

    var errorDescription: String? {
        switch self {
        case .unsupportedMultiplier: return "补帧倍数仅支持 2x 或 4x"
        case .initializationFailed: return "RIFE Metal 推理器初始化失败"
        case .videoTrackNotFound: return "找不到视频轨道"
        case .readerConfigurationFailed: return "无法配置视频读取器"
        case .writerConfigurationFailed: return "无法配置视频写入器"
        case .readerStartFailed: return "视频读取启动失败"
        case .writerStartFailed: return "视频写入启动失败"
        case .noVideoFrames: return "视频没有可读取的帧"
        case .invalidFrameTimestamp: return "视频帧时间戳无效或不连续，无法安全补帧"
        case .inferenceFailed: return "RIFE 补帧推理失败"
        case .writeFailed: return "补帧视频写入失败"
        }
    }
}
