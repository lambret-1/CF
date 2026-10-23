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

    // MARK: - 照片超分（整图缩放极速版，告别切块）
    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        isCancelled = false
        let startTime = Date()
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        var config = MLModelConfiguration()
        config.computeUnits = .all // 满血硬件加速
        
        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: config.computeUnits
        )

        let inputInfo = try ModelInputInfo.parse(from: model)
        
        await AppLogger.shared.log("⚡️ [极速整图] 尺寸: \(image.width)x\(image.height) -> 模型输入: \(inputInfo.width)x\(inputInfo.height)")

        // 模拟进度条起步（因为秒出，其实很快就跑完了）
        progressHandler?(InferenceProgress(
            currentTile: 1, totalTiles: 1, fraction: 0.1,
            elapsedSeconds: 0, estimatedRemainingSeconds: 0
        ))

        let scaleFactor = descriptor.scaleFactor
        let targetWidth = image.width * scaleFactor
        let targetHeight = image.height * scaleFactor

        // 1. 将 CGImage 转换为 CVPixelBuffer 并进行第一次缩放（到模型输入尺寸）
        guard let inputBuffer = resizeCGImageToPixelBuffer(image, targetWidth: inputInfo.width, targetHeight: inputInfo.height) else {
            throw InferenceError.tileProcessingFailed("图片预处理失败")
        }

        // 2. 构建模型输入
        let featureProvider: MLDictionaryFeatureProvider
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入节点")
        }

        if inputInfo.isImageInput {
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: inputBuffer)])
        } else {
            // 如果模型要求 MultiArray，依然用之前的转换器（已经重写为指针极速版）
            let constraint = model.modelDescription.inputDescriptionsByName[inputName]!.multiArrayConstraint!
            // 这里为了速度，直接通过 CIImage 转换出 CGImage 再做 MultiArray
            guard let scaledCG = ciContext.createCGImage(CIImage(cvPixelBuffer: inputBuffer), from: CGRect(x: 0, y: 0, width: inputInfo.width, height: inputInfo.height)) else {
                throw InferenceError.tileProcessingFailed("转换失败")
            }
            let array = try ImageTensorConverter.imageToMultiArray(scaledCG, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        if isCancelled { throw InferenceError.cancelled }

        // 3. 执行单次推理
        let output = try model.prediction(from: featureProvider)
        
        guard let outputName = output.featureNames.first,
              let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("模型输出无效")
        }

        // 4. 获取推理结果并进行最终缩放（到目标分辨率）
        let finalCGImage: CGImage
        
        if let outputBuffer = outputFeature.imageBufferValue {
            // 模型输出是 Image
            finalCGImage = scalePixelBufferToCGImage(outputBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
        } else if let outputArray = outputFeature.multiArrayValue {
            // 模型输出是 MultiArray
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            // 放大到目标尺寸
            finalCGImage = resizeCGImage(rawCGImage, targetWidth: targetWidth, targetHeight: targetHeight)
        } else {
            throw InferenceError.tileProcessingFailed("输出格式不支持")
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

// ==========================================
// ⭐️ 第一段结束，请空一行接着粘贴第二段
// ==========================================

// MARK: - 实时预览（极速版）
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        var config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)

        let targetWidth = image.width * descriptor.scaleFactor
        let targetHeight = image.height * descriptor.scaleFactor

        guard let inputBuffer = resizeCGImageToPixelBuffer(image, targetWidth: inputInfo.width, targetHeight: inputInfo.height) else {
            throw InferenceError.tileProcessingFailed("预处理失败")
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

        let output = try model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("无输出")
        }

        if let outputBuffer = outputFeature.imageBufferValue {
            return scalePixelBufferToCGImage(outputBuffer, targetWidth: targetWidth, targetHeight: targetHeight)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            return resizeCGImage(rawCGImage, targetWidth: targetWidth, targetHeight: targetHeight)
        }
        
        throw InferenceError.tileProcessingFailed("格式不支持")
    }

    // MARK: - 核心极速缩放工具 (CIContext 硬件加速)
    
    private func resizeCGImageToPixelBuffer(_ image: CGImage, targetWidth: Int, targetHeight: Int) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        
        guard CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else { return nil }
              
        let ciImage = CIImage(cgImage: image)
        let scaleX = CGFloat(targetWidth) / CGFloat(image.width)
        let scaleY = CGFloat(targetHeight) / CGFloat(image.height)
        
        // 直接拉伸，极速
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        ciContext.render(scaledImage, to: buffer)
        return buffer
    }

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