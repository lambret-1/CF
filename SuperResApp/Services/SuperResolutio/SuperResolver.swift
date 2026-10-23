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

    // MARK: - 照片超分（动态切块，稳妥极速版）
    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        isCancelled = false
        let startTime = Date()
        
        // ⭐️ 核心修复：先回调一次空进度，瞬间解除 UI 的“加载模型…”状态
        progressHandler?(InferenceProgress(
            currentTile: 0, totalTiles: 1, fraction: 0.01,
            elapsedSeconds: 0, estimatedRemainingSeconds: nil
        ))

        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        let tileSize = inputInfo.width
        let overlap = tileSize / 16 // 极小的重叠

        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: tileSize, overlap: overlap)
        let totalTiles = tiles.count
        let scaleFactor = descriptor.scaleFactor
        let outputWidth = image.width * scaleFactor
        let outputHeight = image.height * scaleFactor

        await AppLogger.shared.log("⚡️ [极速串行] 尺寸: \(image.width)x\(image.height) -> \(tileSize)x\(tileSize) (\(totalTiles)块)")

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
        
        // ⭐️ 核心修复：放弃多线程并发（防止 CoreML 死锁），采用串行推理
        for (index, tile) in tiles.enumerated() {
            if isCancelled { throw InferenceError.cancelled }
            
            // 1. 极速裁剪
            let cropRect = CGRect(x: tile.x, y: tile.y, width: tileSize, height: tileSize)
            let croppedCIImage = ciImage.cropped(to: cropRect)
            let movedCIImage = croppedCIImage.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            
            guard let croppedCG = self.ciContext.createCGImage(movedCIImage, from: CGRect(x: 0, y: 0, width: tileSize, height: tileSize)) else {
                continue
            }
            
            // 2. 推理
            let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
            
            // 3. 拼接
            blendTile(
                context: outputContext,
                tileImage: outputTile,
                tileInfo: tile,
                scaleFactor: scaleFactor,
                overlap: overlap,
                tileSize: tileSize
            )
            
            let elapsed = Date().timeIntervalSince(startTime)
            progressHandler?(InferenceProgress(
                currentTile: index + 1,
                totalTiles: totalTiles,
                fraction: Double(index + 1) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(elapsed: elapsed, completed: index + 1, total: totalTiles)
            ))
        }

        guard let finalOutput = outputContext.makeImage() else {
            throw InferenceError.outputCreationFailed
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return InferenceResult(
            outputImage: finalOutput,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: outputWidth, height: outputToHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: tileSize, totalTiles: totalTiles
        )
    }

    // MARK: - 实时预览（整图极速）
    func fastUpscale(image: CGImage, modelIDImage: String) async throws -> CGImage {
        guard let manifest(output = await manifestLoader.manifestItemArray(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
,        let descriptor = ModelDescriptor.descriptor(for: manifest)

 is        let config = MLModelConfiguration()
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
            let outIsNCHW = outputArray.shape.map { $0.intValue }[1] == 3
            let rawCGImage = try ImageTensorConverter.multiArrayNCHW: outIsNCHW)
            return resizeCGImage(rawCGImage, targetWidth: targetWidth, targetHeight: targetHeight)
        }
        throw InferenceError.tileProcessingFailed("格式不支持")
    }

    // MARK: - 核心工具：智能网格计算
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

    // MARK: - 核心工具：单块推理
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
        
        let cropX = CGFloat(overlap * scaleFactor) / 2
        let cropY = CGFloat(overlap * scaleFactor) / 2
        
        var validRect = CGRect(x: cropX, y: cropY, width: drawWidth - cropX * 2, height: drawHeight - cropY * 2)
        
        if validRect.width <= 0 { validRect.size.width = drawWidth }
        if validRect.height <= 0 { validRect.size.height = drawHeight }
        
        guard let validTile = tileImage.cropping(to: validRect) else { return }
        
        context.saveGState()
        context.translateBy(x: destX + cropX, y: destY + drawHeight - cropY)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(validTile, in: CGRect(x: 0, y: 0, width: validRect.width, height: validRect.height))
        context.restoreGState()
    }

    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        return (elapsed / Double(completed)) * Double(total - completed)
    }

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
        
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
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