// SuperResApp/Services/SuperResolutio/Engines/DirectStretchEngine.swift

import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct DirectStretchEngine: SuperResolutionEngine {
    // ⭐️ 配置 GPU 加速，关闭色彩空间转换（大幅提升渲染速度）
    private static let ciContext = CIContext(options: [
        .workingColorSpace: NSNull(),
        .useSoftwareRenderer: false
    ])

    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> EngineResult { 
        
        let startTime = Date()
        
        progressHandler?(InferenceProgress(
            currentTile: 0, totalTiles: 1, fraction: 0.1, elapsedSeconds: 0, estimatedRemainingSeconds: 0
        ))

        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入")
        }

        let featureProvider: MLDictionaryFeatureProvider
        
        if inputInfo.isImageInput {
            guard let inputBuffer = makeBGRAPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height) else {
                throw InferenceError.tileProcessingFailed("创建 Buffer 失败")
            }
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
        } else {
            guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint else {
                throw InferenceError.tileProcessingFailed("无多数组约束")
            }
            
            let ciImage = CIImage(cgImage: image)
            let scaledCI = ciImage.transformed(by: CGAffineTransform(
                scaleX: CGFloat(inputInfo.width) / CGFloat(image.width), 
                y: CGFloat(inputInfo.height) / CGFloat(image.height)
            ))
            
            let cropRect = CGRect(x: 0, y: 0, width: inputInfo.width, height: inputInfo.height)
            let finalCI = scaledCI.cropped(to: cropRect)
            
            guard let scaledCG = Self.ciContext.createCGImage(finalCI, from: finalCI.extent) else {
                throw InferenceError.tileProcessingFailed("缩放转换失败")
            }
            
            let array = try ImageTensorConverter.imageToMultiArray(scaledCG, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        // ⚡️ 核心推理
        let output = try await model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("无输出")
        }

        let targetWidth = image.width * scaleFactor
        let targetHeight = image.height * scaleFactor
        
        var finalCGImage: CGImage
        
        if let outputBuffer = outputFeature.imageBufferValue {
            // ⭐️ 优化：如果是 ImageBuffer 输出，直接用 CIImage 处理
            let ciImage = CIImage(cvPixelBuffer: outputBuffer)
            let scaleX = CGFloat(targetWidth) / CGFloat(CVPixelBufferGetWidth(outputBuffer))
            let scaleY = CGFloat(targetHeight) / CGFloat(CVPixelBufferGetHeight(outputBuffer))
            let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            
            guard let cgImage = Self.ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
                throw InferenceError.tileProcessingFailed("输出 Buffer 转 CGImage 失败")
            }
            finalCGImage = cgImage
            
        } else if let outputArray = outputFeature.multiArrayValue {
            var outIsNCHW = false
            let shape = outputArray.shape.map { $0.intValue }
            if shape.count == 4 {
                if shape[1] == 3 || shape[1] == 4 { outIsNCHW = true }
            }
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            
            let ciImage = CIImage(cgImage: rawCGImage)
            let scaleX = CGFloat(targetWidth) / CGFloat(rawCGImage.width)
            let scaleY = CGFloat(targetHeight) / CGFloat(rawCGImage.height)
            let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
            
            guard let cgImage = Self.ciContext.createCGImage(scaledImage, from: scaledImage.extent) else {
                throw InferenceError.tileProcessingFailed("输出 Array 转 CGImage 失败")
            }
            finalCGImage = cgImage
        } else {
            throw InferenceError.tileProcessingFailed("格式不支持")
        }
        
        if modelID == "piper-sr-2x" {
            let ciImage = CIImage(cgImage: finalCGImage)
            let flipped = ciImage.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ciImage.extent.height))
            guard let flippedCG = Self.ciContext.createCGImage(flipped, from: flipped.extent) else {
                throw InferenceError.tileProcessingFailed("图像翻转失败")
            }
            finalCGImage = flippedCG
        }
        
        let elapsed = Date().timeIntervalSince(startTime)
        progressHandler?(InferenceProgress(
            currentTile: 1, totalTiles: 1, fraction: 1.0, elapsedSeconds: elapsed, estimatedRemainingSeconds: 0
        ))

        return EngineResult(image: finalCGImage, tileSize: inputInfo.width, totalTiles: 1)
    }

    // ⭐️ 优化：抛弃极慢的 CGContext.draw，改用 GPU 渲染
    private func makeBGRAPixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true, 
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary // ⭐️ 允许 GPU 直接操作
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        
        let ciImage = CIImage(cgImage: image)
        let scaleX = CGFloat(width) / ciImage.extent.width
        let scaleY = CGFloat(height) / ciImage.extent.height
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        Self.ciContext.render(scaledImage, to: buffer)
        
        return buffer
    }
}