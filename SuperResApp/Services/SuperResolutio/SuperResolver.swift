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

    // MARK: - 照片超分（并发极速切块版）
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
        
        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        let tileSize = inputInfo.width
        let overlap = tileSize / 16 // 极小的重叠，避免接缝同时保证速度

        // 计算切块坐标
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: tileSize, overlap: overlap)
        let totalTiles = tiles.count
        let scaleFactor = descriptor.scaleFactor
        let outputWidth = image.width * scaleFactor
        let outputHeight = image.height * scaleFactor

        await AppLogger.shared.log("⚡️ [并发切块] 尺寸: \(image.width)x\(image.height) -> 块数: \(totalTiles)")

        // 创建最终输出画布
        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        outputContext.translateBy(x: 0, y: CGFloat(outputHeight))
        outputContext.scaleBy(x: 1.0, y: -1.0)

        let ciImage = CIImage(cgImage: image)
        var completedTiles = 0
        
        // ⭐️ 核心修复：多线程并发推理，利用所有 CPU/GPU 核心
        try await withThrowingTaskGroup(of: (Int, CGImage?).self) { group in
            for (index, tile) in tiles.enumerated() {
                if isCancelled { throw InferenceError.cancelled }
                
                group.addTask {
                    // 1. 使用 CIContext 进行极速裁剪 (GPU加速)
                    let cropRect = CGRect(x: tile.x, y: tile.y, width: tileSize, height: tileSize)
                    let croppedCIImage = ciImage.cropped(to: cropRect)
                    let movedCIImage = croppedCIImage.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
                    
                    guard let croppedCG = self.ciContext.createCGImage(movedCIImage, from: CGRect(x: 0, y: 0, width: tileSize, height: tileSize)) else {
                        return (index, nil)
                    }
                    
                    // 2. 推理 (调用 nonisolated 方法，无需 await)
                    do {
                        let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
                        return (index, outputTile)
                    } catch {
                        return (index, nil)
                    }
                }
            }
            
            // 3. 收集结果并拼接
            for try await (index, outputTile) in group {
                if isCancelled { throw InferenceError.cancelled }
                
                if let outputTile = outputTile {
                    blendTile(
                        context: outputContext,
                        tileImage: outputTile,
                        tileInfo: tiles[index],
                        scaleFactor: scaleFactor,
                        overlap: overlap,
                        tileSize: tileSize
                    )
                }
                
                completedTiles += 1
                let elapsed = Date().timeIntervalSince(startTime)
                progressHandler?(InferenceProgress(
                    currentTile: completedTiles,
                    totalTiles: totalTiles,
                    fraction: Double(completedTiles) / Double(totalTiles),
                    elapsedSeconds: elapsed,
                    estimatedRemainingSeconds: estimateRemaining(elapsed: elapsed, completed: completedTiles, total: totalTiles)
                ))
            }
        }

        guard let finalOutput = outputContext.makeImage() else {
            throw InferenceError.outputCreationFailed
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return InferenceResult(
            outputImage: finalOutput,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: tileSize, totalTiles: totalTiles
        )
    }

    // MARK: - 实时预览（保持整图极速）
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)

        let (inputBuffer, validRect) = try createLetterboxedPixelBuffer(from: image, targetWidth: inputInfo.width, targetHeight: inputInfo.height)
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
            return try processOutput(ciImage: CIImage(cvPixelBuffer: outputBuffer), validRect: validRect, scaleFactor: descriptor.scaleFactor, targetWidth: targetWidth, targetHeight: targetHeight, needsFlip: false)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            let rawCGImage = try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
            return try processOutput(ciImage: CIImage(cgImage: rawCGImage), validRect: validRect, scaleFactor: descriptor.scaleFactor, targetWidth: targetWidth, targetHeight: targetHeight, needsFlip: true)
        }
        throw InferenceError.tileProcessingFailed("格式不支持")
    }

    // MARK: - 核心工具：网格计算
    private struct TileInfo {
        let x: Int; let y: Int; let width: Int; let height: Int
    }

    private func calculateTiles(width: Int, height: Int, tileSize: Int, overlap: Int) -> [TileInfo] {
        var tiles: [TileInfo] = []
        let step = max(1, tileSize - overlap)
        
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let startX = min(x, max(0, width - tileSize))
                let startY = min(y, max(0, height - tileSize))
                let validWidth = min(tileSize, width)
                let validHeight = min(tileSize, height)
                tiles.append(TileInfo(x: startX, y: startY, width: validWidth, height: validHeight))
                
                if x + tileSize >= width { break }
                x += step
            }
            if y + tileSize >= height { break }
            y += step
        }
        return tiles
    }

    // MARK: - 核心工具：单块推理 (⭐️ 加上 nonisolated 摆脱 actor 限制)
    nonisolated private func processTile(image: CGImage, model: MLModel, inputInfo: ModelInputInfo) throws -> CGImage {
        let featureProvider: MLDictionaryFeatureProvider
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入节点")
        }

        if inputInfo.isImageInput {
            let pixelBuffer = try ImageTensorConverter.createPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height, pixelFormat: kCVPixelFormatType_32BGRA)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        } else {
            let constraint = model.modelDescription.inputDescriptionsByName[inputName]!.multiArrayConstraint!
            let array = try ImageTensorConverter.imageToMultiArray(image, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        let output = try model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("模型输出无效")
        }

        if let outputBuffer = outputFeature.imageBufferValue {
            return try ImageTensorConverter.createCGImage(from: outputBuffer)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }

    // MARK: - 核心工具：拼接
    private func blendTile(context: CGContext, tileImage: CGImage, tileInfo: TileInfo, scaleFactor: Int, overlap: Int, tileSize: Int) {
        let drawWidth = CGFloat(tileInfo.width * scaleFactor)
        let drawHeight = CGFloat(tileInfo.height * scaleFactor)
        let destX = CGFloat(tileInfo.x * scaleFactor)
        let destY = CGFloat(tileInfo.y * scaleFactor)
        
        // 为了防止边缘接缝，裁掉一点点边缘
        let cropX = CGFloat(overlap * scaleFactor) / 2
        let cropY = CGFloat(overlap * scaleFactor) / 2
        
        var validRect = CGRect(x: cropX, y: cropY, width: drawWidth - cropX * 2, height: drawHeight - cropY * 2)
        
        // 边界保护
        if validRect.width <= 0 { validRect.size.width = drawWidth }
        if validRect.height <= 0 { validRect.size.height = drawHeight }
        
        guard let validTile = tileImage.cropping(to: validRect) else { return }
        
        context.saveGState()
        // 注意这里要对齐
        context.translateBy(x: destX + cropX, y: destY + drawHeight - cropY)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(validTile, in: CGRect(x: 0, y: 0, width: validRect.width, height: validRect.height))
        context.restoreGState()
    }

    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        return (elapsed / Double(completed)) * Double(total - completed)
    }

    // MARK: - 其他工具
    private func createLetterboxedPixelBuffer(from image: CGImage, targetWidth: Int, targetHeight: Int) throws -> (CVPixelBuffer, CGRect) {
        var pixelBuffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA, kCVPixelBufferWidthKey: targetWidth, kCVPixelBufferHeightKey: targetHeight, kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        guard CVPixelBufferCreate(kCFAllocatorDefault, targetWidth, targetHeight, kCVPixelFormatType_32BGRA, attrs, &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer else { throw InferenceError.tileProcessingFailed("创建 Buffer 失败") }
        
        let blackImage = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1)).cropped(to: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight))
        let ciImage = CIImage(cgImage: image)
        let scale = min(CGFloat(targetWidth) / ciImage.extent.width, CGFloat(targetHeight) / ciImage.extent.height)
        
        let scaledWidth = ciImage.extent.width * scale
        let scaledHeight = ciImage.extent.height * scale
        let xOffset = (CGFloat(targetWidth) - scaledWidth) / 2.0
        let yOffset = (CGFloat(targetHeight) - scaledHeight) / 2.0
        
        let scaledImage = ciImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let translatedImage = scaledImage.transformed(by: CGAffineTransform(translationX: xOffset, y: yOffset))
        let flippedImage = translatedImage.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(targetHeight)).scaledBy(x: 1, y: -1))
        
        ciContext.render(flippedImage.composited(over: blackImage), to: buffer)
        
        return (buffer, CGRect(x: xOffset, y: CGFloat(targetHeight) - yOffset - scaledHeight, width: scaledWidth, height: scaledHeight))
    }

    private func processOutput(ciImage: CIImage, validRect: CGRect, scaleFactor: Int, targetWidth: Int, targetHeight: Int, needsFlip: Bool) throws -> CGImage {
        let outRect = CGRect(x: validRect.origin.x * CGFloat(scaleFactor), y: validRect.origin.y * CGFloat(scaleFactor), width: validRect.width * CGFloat(scaleFactor), height: validRect.height * CGFloat(scaleFactor))
        let croppedImage = ciImage.cropped(to: outRect)
        let finalImage = croppedImage.transformed(by: CGAffineTransform(translationX: -outRect.origin.x, y: -outRect.origin.y))
        
        let scaleX = CGFloat(targetWidth) / outRect.width
        let scaleY = CGFloat(targetHeight) / outRect.height
        var resizedImage = finalImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
        
        if needsFlip { resizedImage = resizedImage.transformed(by: CGAffineTransform(translationX: 0, y: CGFloat(targetHeight)).scaledBy(x: 1, y: -1)) }
        guard let cgImage = ciContext.createCGImage(resizedImage, from: CGRect(x: 0, y: 0, width: targetWidth, height: targetHeight)) else { throw InferenceError.outputCreationFailed }
        return cgImage
    }
}