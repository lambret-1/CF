// SuperResApp/Services/SuperResolutio/SuperResolver.swift

import Foundation
import CoreML
import CoreImage
import UIKit
import CoreVideo

actor SuperResolver {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    private var isCancelled = false
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private init() {}

    func cancel() { isCancelled = true }

    // MARK: - 照片超分（Model Zoo 官方极简极速版）
    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        isCancelled = false
        let startTime = Date()
        
        // 1. 秒出进度条（防止卡在“加载模型”）
        progressHandler?(InferenceProgress(
            currentTile: 0, totalTiles: 1, fraction: 0.1,
            elapsedSeconds: 0, estimatedRemainingSeconds: 0
        ))

        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        await AppLogger.shared.log("🚀 [官方极简版] 尺寸: \(image.width)x\(image.height) -> 模型输入: \(inputInfo.width)x\(inputInfo.height)")

        // 2. 官方做法：暴力拉伸，直接填满模型
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

        if isCancelled { throw InferenceError.cancelled }

        // 3. 单次推理
        let output = try await model.prediction(from: featureProvider)
        
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("无输出")
        }

        // 4. 拿结果并放大到目标尺寸
        let scaleFactor = descriptor.scaleFactor
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

        let elapsed = Date().timeIntervalSince(startTime)
        
        progressHandler?(InferenceProgress(
            currentTile: 1, totalTiles: 1, fraction: 1.0,
            elapsedSeconds: elapsed, estimatedRemainingSeconds: 0
        ))

        return InferenceResult(
            outputImage: finalCGImage,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: targetWidth, height: targetHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: inputInfo.width, totalTiles: 1
        )
    }

    // MARK: - 实时预览（同款逻辑）
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        guard let inputBuffer = makeBGRAPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height) else {
            throw InferenceError.tileProcessingFailed("创建 Buffer 失败")
        }
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else { throw InferenceError.tileProcessingFailed("无输入") }

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

        let output = try await model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("无输出")
        }
        
        let targetWidth = image.width * descriptor.scaleFactor
        let targetHeight = image.height * descriptor.scaleFactor

        if let outputBuffer = outputFeature.imageBufferValue {
            return scalePixelBufferToCGImage(outputBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape[1].intValue == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            return resizeCGImage(rawCGImage, targetWidth: targetWidth, targetHeight: targetHeight)
        }
        throw InferenceError.tileProcessingFailed("格式不支持")
    }

    // MARK: - 官方代码复刻：暴力拉伸 BGRA Buffer
    private func makeBGRAPixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        // 关键：直接拉伸画进去，没有任何黑边！
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    // MARK: - CIContext 极速缩放
    private func scalePixelBufferToCGImage(_ buffer: CVPixelBuffer, targetWidth: Int, targetHeight: Int) -> CGImage {
        let ciImage = CIImage(cvPixelBuffer: buffer)
        let scaleX = CGFloat(targetWidth) / CGFloat(CVPixelBufferGetWidth(buffer))
        let scaleY = CGFloat(targetHeight) / CGFloat(CVPixelBufferGetHeight(buffer))
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return ciContext.createCGImage(scaledImage, from: scaledImage.extent)!
    }

    private func resizeCGImage(_ image: CGImage, targetWidth: Int, targetHeight: Int) -> CGImage {
        let ciImage = CIImage(cgImage: image)
        let scaleX = CGFloat(targetWidth) / CGFloat(image.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(image.height)
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        return ciContext.createCGImage(scaledImage, from: scaledImage.extent)!
    }
}