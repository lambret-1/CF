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
        progressHandler: @escaping @MainActor @Sendable (Double) -> Void
    ) async throws {
        guard multiplier == 2 || multiplier == 4 else {
            throw FrameInterpolationError.unsupportedMultiplier
        }
        cancelLock.withLock { cancelled = false }

        let model = try await ModelStore.shared.loadFrameInterpolationModel()
        guard let interpolator = FrameInterpolator(model: model) else {
            throw FrameInterpolationError.initializationFailed
        }

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
                        if Task.isCancelled { break }
                        try? await Task.sleep(nanoseconds: 5_000_000)
                    }
                    if Task.isCancelled { break }
                    _ = audioInput.append(sample)
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
            let estimatedFrames = max(1, Int((CMTimeGetSeconds(duration) * Double(try await videoTrack.load(.nominalFrameRate))).rounded(.up)))

            while let sample = videoOutput.copyNextSampleBuffer() {
                try checkCancellation()
                guard let currentBuffer = CMSampleBufferGetImageBuffer(sample) else { continue }
                let currentTime = CMSampleBufferGetPresentationTimeStamp(sample)
                let delta = CMTimeSubtract(currentTime, previousTime)

                try await append(previousBuffer, at: previousTime, adaptor: adaptor, input: videoInput, writer: writer)

                // RIFE 输出中间帧；4x 通过递归二分得到 1/4、1/2、3/4。
                if multiplier == 2 {
                    guard let middle = interpolator.interpolate(frame0: previousBuffer, frame1: currentBuffer) else {
                        throw FrameInterpolationError.inferenceFailed
                    }
                    try checkCancellation()
                    let time = CMTimeAdd(previousTime, CMTimeMultiplyByRatio(delta, multiplier: 1, divisor: 2))
                    try await append(middle, at: time, adaptor: adaptor, input: videoInput, writer: writer)
                } else {
                    guard let middle = interpolator.interpolate(frame0: previousBuffer, frame1: currentBuffer),
                          let quarter = interpolator.interpolate(frame0: previousBuffer, frame1: middle),
                          let threeQuarter = interpolator.interpolate(frame0: middle, frame1: currentBuffer) else {
                        throw FrameInterpolationError.inferenceFailed
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
            }

            try checkCancellation()
            try await append(previousBuffer, at: previousTime, adaptor: adaptor, input: videoInput, writer: writer)
            videoInput.markAsFinished()
            await audioTask?.value
            try await finish(writer)
            await progressHandler(1.0)
        } catch {
            audioTask?.cancel()
            reader.cancelReading()
            writer.cancelWriting()
            try? FileManager.default.removeItem(at: outputURL)
            throw error
        }
    }

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
        case .inferenceFailed: return "RIFE 补帧推理失败"
        case .writeFailed: return "补帧视频写入失败"
        }
    }
}
