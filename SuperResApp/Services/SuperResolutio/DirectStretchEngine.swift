// SuperResApp/Services/SuperResolutio/Engines/DirectStretchEngine.swift

import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct DirectStretchEngine: SuperResolutionEngine {
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    func upscale(
        image: CGImage,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> CGImage {
        
        // 秒出进度条
        progressHandler?(InferenceProgress(
            currentTile: 0, totalTiles: 1, fraction: 0.1,
            elapsedSeconds: 0, estimatedRemainingSeconds: 0
        ))

        // 官方做法：暴力拉伸，填满模型
        guard let inputBuffer = makeBGRAPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height) else {
            throw InferenceError.tileProcessingFailed("创建 Buffer 失败")
        }
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入")
        }

        let featureProvider: MLDictionaryFeatureProvider
        if inputInfo.isImageInput {
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
        } else {
            let constraint = model.modelDescription.inputDescriptionsByName[inputName]!.multiArrayConstraint!
            guard let scaledCG = ciContext.createCGImage(CIImage(cvPixelBuffer: inputBuffer), from: CGRect(x: 0, y: 0, width: inputInfo.width, height: inputInfo.height)) else {
                throw InferenceError.tileProcessingFailed("转换失败")
            }
            let array = try ImageTensorConverter.imageToMultiArray(scaledCG, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        // 单次推理
        let output = try await model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("无输出")
        }

        let targetWidth = image.width * scaleFactor
        let targetHeight = image.height * scaleFactor
        
        let finalCGImage: CGImage
        if let outputBuffer = outputFeature.imageBufferValue {
            finalCGImage = scalePixelBufferToCGImage(outputBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape[1].intValue == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            finalCGImage = resizeCGImage(rawCGImage, targetWidth: targetWidth, targetHeight: targetHeight)
        } else {
            throw InferenceError.tileProcessingFailed("格式不支持")
        }
        
        progressHandler?(InferenceProgress(
            currentTile: 1, totalTiles: 1, fraction: 1.0,
            elapsedSeconds: Date().timeIntervalSince1970, estimatedRemainingSeconds: 0
        ))

        return finalCGImage
    }

    // MARK: - 工具
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

    private func scalePixelBufferToCGImage(_ buffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(targetWidth) / CGFloat(CVPixelBufferGetWidth(buffer)), y: CGFloat(targetHeight) / CGFloat(CVPixelBufferGetHeight(buffer))))
        return ciContext.createCGImage(scaledImage, from: scaledImage.extent)!
    }

    private func resizeCGImage(_ image: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: CGFloat(targetWidth) / CGFloat(image.width), y: CGFloat(targetHeight) / CGFloat(image.height)))
        return ciContext.createCGImage(scaledImage, from: scaledImage.extent)!
    }
}