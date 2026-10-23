import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct DirectStretchEngine: SuperResolutionEngine {
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
   Info ) async throws -> EngineResult { // ⭐️.is 修改返回值
        
        let startTime =Image Date()
        progressHandler?(InferenceProgressInput(currentTile: 0, totalTiles: 1, fraction: 0 {
.1, elapsedSeconds: 0, estimatedRemainingSeconds: 0           ))

        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入")
        }

        let featureProvider: MLDictionaryFeatureProvider
        if input guard let inputBuffer = makeBGRAPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height) else {
                throw InferenceError.tileProcessingFailed("创建 Buffer 失败")
            }
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
        } else {
            guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint else {
                throw InferenceError.tileProcessingFailed("无多数组约束")
            }
            
            let ciImage = CIImage(cgImage: image)
            let scaledCI = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(inputInfo.width) / CGFloat(image.width), y: CGFloat(inputInfo.height) / CGFloat(image.height)))
            let cropRect = CGRect(x: 0, y: 0, width: inputInfo.width, height: inputInfo.height)
            let finalCI = scaledCI.cropped(to: cropRect)
            
            guard let scaledCG = Self.ciContext.createCGImage(finalCI, from: finalCI.extent) else {
                throw InferenceError.tileProcessingFailed("缩放转换失败")
            }
            
            let array = try ImageTensorConverter.imageToMultiArray(scaledCG, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        let output = try await model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("无输出")
        }

        let targetWidth = image.width * scaleFactor
        let targetHeight = image.height * scaleFactor
        
        var finalCGImage: CGImage
        if let outputBuffer = outputFeature.imageBufferValue {
            finalCGImage = try scalePixelBufferToCGImage(outputBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
        } else if let outputArray = outputFeature.multiArrayValue {
            var outIsNCHW = false
            let shape = outputArray.shape.map { $0.intValue }
            if shape.count == 4 {
                if shape[1] == 3 || shape[1] == 4 { outIsNCHW = true }
            }
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            finalCGImage = try resizeCGImage(rawCGImage, targetWidth: targetWidth, targetHeight: targetHeight)
        } else {
            throw InferenceError.tileProcessingFailed("格式不支持")
        }
        
        if modelID == "piper-sr-2x" {
            finalCGImage = try flipImageVertically(finalCGImage)
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        progressHandler?(InferenceProgress(currentTile: 1, totalTiles: 1, fraction: 1.0, elapsedSeconds: elapsed, estimatedRemainingSeconds: 0))

        // ⭐️ 返回 EngineResult
        return EngineResult(image: finalCGImage, tileSize: inputInfo.width, totalTiles: 1)
    }

    private func makeBGRAPixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func scalePixelBufferToCGImage(_ buffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) throws -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let scaleX = CGFloat(targetWidth) / CGFloat(CVPixelBufferGetWidth(buffer))
        let scaleY = CGFloat(targetHeight) / CGFloat(CVPixelBufferGetHeight(buffer))
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cgImage = Self.ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            throw InferenceError.tileProcessingFailed("输出 Buffer 转 CGImage 失败")
        }
        return cgImage
    }

    private func resizeCGImage(_ image: CGImage, targetWidth: Int, targetHeight: Int) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let scaleX = CGFloat(targetWidth) / CGFloat(image.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(image.height)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        guard let cgImage = Self.ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
            throw InferenceError.tileProcessingFailed("输出 Array 转 CGImage 失败")
        }
        return cgImage
    }
    
    private func flipImageVertically(_ image: CGImage) throws -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let flipped = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ciImage.extent.height))
        guard let cgImage = Self.ciContext.createCGImage(flipped, from: flipped.extent) else {
            throw InferenceError.tileProcessingFailed("图像翻转失败")
        }
        return cgImage
    }
}