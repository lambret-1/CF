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
        
        let transformedSize = naturalSize.applying(preferredTransform)
        let pixelWidth = abs(transformedSize.width)
        let pixelHeight = abs(transformedSize.height)
        
        let targetWidth = pixelWidth * CGFloat(scaleFactor)
        let targetHeight = pixelHeight * CGFloat(scaleFactor)
        
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
        }
        
        let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
        let videoCompressionProperties: [String: Any] = [
            AVVideoAverageBitRateKey: Int(targetWidth * targetHeight * 5),
            AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel
        ]
        let writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: targetWidth,
            AVVideoHeightKey: targetHeight,
            AVVideoCompressionPropertiesKey: videoCompressionProperties
        ])
        writerVideoInput.expectsMediaDataInRealTime = false
        writer.add(writerVideoInput)
        
        var writerAudioInput: AVAssetWriterInput?
        if let audioTrack = audioTrack {
            let audioOutputSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 2,
                AVSampleRateKey: 44100.0,
                AVEncoderBitRateKey: 128000
            ]
            writerAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: audioOutputSettings)
            if let audioInput = writerAudioInput { writer.add(audioInput) }
        }
        
        guard reader.startReading() else { throw reader.error ?? NSError(domain: "VideoSR", code: 500, userInfo: nil) }
        guard writer.startWriting() else { throw writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: nil) }
        
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
                                continuation.resume(throwing: writer.error ?? NSError(domain: "VideoSR", code: 500, userInfo: nil))
                            }
                        }
                        return
                    }
                    
                    autoreleasepool {
                        guard let imageBuffer = CMSampleBufferGetImageBuffer(videoSampleBuffer) else { return }
                        let timestamp = CMSampleBufferGetPresentationTimeStamp(videoSampleBuffer)
                        
                        let ciImage = CIImage(cvPixelBuffer: imageBuffer)
                        guard let cgImage = self.ciContext.createCGImage(ciImage, from: ciImage.extent) else { return }
                        
                        let semaphore = DispatchSemaphore(value: 0)
                        var superResCGImage: CGImage?
                        
                        Task {
                            do {
                                let result = try await SuperResolver.shared.fastUpscale(
                                    image: cgImage,
                                    modelID: modelID
                                )
                                superResCGImage = result
                            } catch {}
                            semaphore.signal()
                        }
                        
                        semaphore.wait()
                        
                        if let superResCGImage = superResCGImage {
                            if let newBuffer = self.pixelBuffer(from: superResCGImage, width: Int(targetWidth), height: Int(targetHeight)) {
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
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
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