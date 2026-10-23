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

    // MARK: - 照片超分（等比例极速版）
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

        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: config.computeUnits
        )

        let inputInfo = try ModelInputInfo.parse(from: model)
        
        await AppLogger.shared.log("⚡️ [等比例极速] 尺寸: \(image.width)x\(image.height) -> 模型: \(inputInfo.width)x\(inputInfo.height)")

        progressHandler?(InferenceProgress(
            currentTile: 1, totalTiles: 1, fraction: 0.1,
            elapsedSeconds: 0, estimatedRemainingSeconds: 0
        ))

        // 1. 等比例缩放并填充黑边 (Letterboxing)
        let (inputBuffer, validRect) = try createLetterboxedPixelBuffer(
            from: image,
            targetWidth: inputInfo.width,
            targetHeight: inputInfo.height
        )

        // 2. 构建模型输入
        let featureProvider: MLDictionaryFeatureProvider
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入节点")
        }

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

        // 3. 执行单次推理
        let output = try await model.prediction(from: featureProvider)
        
        guard let outputName = output.featureNames.first,
              let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("模型输出无效")
        }

        // 4. 提取输出，裁掉黑边，并放大回目标尺寸
        let finalCGImage: CGImage
        let scaleFactor = descriptor.scaleFactor
        let targetWidth = image.width * scaleFactor
        let targetHeight = image.height * scaleFactor
        
        if let outputBuffer = outputFeature.imageBufferValue {
            finalCGImage = try processOutput(
                ciImage: CIImage(cvPixelBuffer: outputBuffer),
                validRect: validRect,
                scaleFactor: scaleFactor,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            finalCGImage = try processOutput(
                ciImage: CIImage(cgImage: rawCGImage),
                validRect: validRect,
                scaleFactor: scaleFactor,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
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

// MARK: - 实时预览（等比例极速版）
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)

        let (inputBuffer, validRect) = try createLetterboxedPixelBuffer(
            from: image,
            targetWidth: inputInfo.width,
            targetHeight: inputInfo.height
        )

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
            return try processOutput(
                ciImage: CIImage(cvPixelBuffer: outputBuffer),
                validRect: validRect,
                scaleFactor: descriptor.scaleFactor,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            return try processOutput(
                ciImage: CIImage(cgImage: rawCGImage),
                validRect: validRect,
                scaleFactor: descriptor.scaleFactor,
                targetWidth: targetWidth,
                targetHeight: targetHeight
            )
        }
        
        throw InferenceError.tileProcessingFailed("格式不支持")
    }

    // MARK: - 核心工具：等比例填充黑边 (Aspect Fit)
    private func createLetterboxedPixelBuffer(from image: CGImage, targetWidth: Int, targetHeight: Int) throws -> (CVPixelBuffer, CGRect) {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey: targetWidth,
            kCVPixelBufferHeightKey: targetHeight,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ] as CFDictionary
        
        guard CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess,
              let buffer = pixelBuffer else {
            throw InferenceError.tileProcessingFailed("创建 Buffer 失败")
        }
        
        // 填充黑底
        CVPixelBufferLockBaseAddress(buffer, [])
        memset(CVPixelBufferGetBaseAddress(buffer), 0, CVPixelBufferGetDataSize(buffer))
        CVPixelBufferUnlockBaseAddress(buffer, [])
        
        let ciImage = CIImage(cgImage: image)
        let scale = min(CGFloat(targetWidth) / ciImage.extent.width, CGFloat(targetHeight) / ciImage.extent.height)
        
        let scaledWidth = ciImage.extent.width * scale
        let scaledHeight = ciImage.extent.height * scale
        let xOffset = (CGFloat(targetWidth) - scaledWidth) / 2.0
        let yOffset = (CGFloat(targetHeight) - scaledHeight) / 2.0
        
        // ⭐️ 核心修复：在 CoreImage 坐标系中缩放，并注意 Y 轴翻转问题
        // CIImage 渲染到 CVPixelBuffer 时，如果没有指定原点，默认是从左上角开始。
        // 为保证正向，我们使用 CGAffineTransform 同时处理缩放和居中。
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translatedImage = scaledImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
        
        ciContext.render(translatedImage, to: buffer)
        
        // 记录有效区域，以便后续从输出中裁掉黑边
        let validRect = CGRect(x: xOffset, y: yOffset, width: scaledWidth, height: scaledHeight)
        return (buffer, validRect)
    }

    // MARK: - 核心工具：从模型输出中裁掉黑边，并拉伸到目标尺寸
    private func processOutput(ciImage: CIImage, validRect: CGRect, scaleFactor: Int, targetWidth: Int, targetHeight: Int) throws -> CGImage {
        // 根据放大倍数，计算出在模型输出图中的有效区域
        let outRect = CGRect(
            x: validRect.origin.x * CGFloat(scaleFactor),
            y: validRect.origin.y * CGFloat(scaleFactor),
            width: validRect.width * CGFloat(scaleFactor),
            height: validRect.height * CGFloat(scaleFactor)
        )
        
        // 裁剪出有效区域
        let croppedImage = ciImage.cropped(to: outRect)
        
        // 将原点移回 (0,0)
        let finalImage = croppedImage.transformed(by: CGAffineTransform(translationX: -outRect.origin.x, y: -outRect.origin.y))
        
        // 缩放到最终尺寸
        let scaleX = CGFloat(targetWidth) / outRect.width
        let scaleY = CGFloat(targetHeight) / outRect.height
        let resizedImage = finalImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        guard let cgImage = ciContext.createCGImage(resizedImage, from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)) else {
            throw InferenceError.outputCreationFailed
        }
        
        return cgImage
    }
}