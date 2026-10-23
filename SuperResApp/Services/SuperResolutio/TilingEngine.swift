// SuperResApp/Services/SuperResolutio/Engines/TilingEngine.swift

import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct TilingEngine: SuperResolutionEngine {
    // ⭐️ 提取为静态属性，避免反复分配内存
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> CGImage {
        
        let startTime = Date()
        progressHandler?(InferenceProgress(currentTile: 0, totalTiles: 1, fraction: 0.01, elapsedSeconds: 0, estimatedRemainingSeconds: nil))

        let tileSize = inputInfo.width
        let overlap = tileSize / 16 
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: tileSize, overlap: overlap)
        let totalTiles = tiles.count
        
        let outputWidth = image.width * scaleFactor
        let outputHeight = image.height * scaleFactor

        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        for (index, tile) in tiles.enumerated() {
            try autoreleasepool {
                let cropRect = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
                guard let croppedCG = image.cropping(to: cropRect) else { return }
                
                // ⭐️ 修复 1：补齐边缘图像。如果切下来的块不够 128x128，用边缘拉伸补齐
                let paddedTile = padImageIfNeeded(croppedCG, targetSize: tileSize)
                
                // 模型推理
                var outputTile = try self.processTile(image: paddedTile, model: model, inputInfo: inputInfo)
                
                // ⭐️ 修复 4：因为 x4plus 这类模型是多维数组，转成 CGImage 后必定是倒的。在这里把它翻正。
                let ci = CIImage(cgImage: outputTile)
                let flipped = ci.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -ci.extent.height))
                if let flippedCG = Self.ciContext.createCGImage(flipped, from: flipped.extent) {
                    outputTile = flippedCG
                }
                
                // 计算绘制区域
                let drawWidth = CGFloat(tile.width) * CGFloat(scaleFactor)
                let drawHeight = CGFloat(tile.height) * CGFloat(scaleFactor)
                let destX = CGFloat(tile.x) * CGFloat(scaleFactor)
                let destY = CGFloat(tile.y) * CGFloat(scaleFactor)
                
                // 坐标转换（CGContext 左下角原点）
                let cgY = CGFloat(outputHeight) - destY - drawHeight
                
                // 因为可能被 Padding 补齐过，需要裁剪出有效区域画到画布上
                let safeWidth = min(Int(drawWidth), outputTile.width)
                let safeHeight = min(Int(drawHeight), outputTile.height)
                
                if let validTile = outputTile.cropping(to: CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)) {
                    outputContext.draw(validTile, in: CGRect(x: destX, y: cgY, width: drawWidth, height: drawHeight))
                }
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            progressHandler?(InferenceProgress(
                currentTile: index + 1, totalTiles: totalTiles, fraction: Double(index + 1) / Double(totalTiles),
                elapsedSeconds: elapsed, estimatedRemainingSeconds: (elapsed / Double(index + 1)) * Double(totalTiles - index - 1)
            ))
        }

        guard let finalOutput = outputContext.makeImage() else { throw InferenceError.outputCreationFailed }
        return finalOutput
    }

    // MARK: - 辅助方法

    /// ⭐️ 新增：将尺寸不足的图像通过边缘拉伸补齐到目标尺寸，防止模型输入越界
    private func padImageIfNeeded(_ image: CGImage, targetSize: Int) -> CGImage {
        if image.width == targetSize && image.height == targetSize {
            return image
        }
        let ciImage = CIImage(cgImage: image)
        // 边缘拉伸
        let clamped = ciImage.clampedToExtent()
        // 锚定左上角向右下角扩展
        let translateY = CGFloat(targetSize - image.height)
        let transformed = clamped.transformed(by: CGAffineTransform(translationX: 0, y: translateY))
        let cropRect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        let padded = transformed.cropped(to: cropRect)
        
        if let result = Self.ciContext.createCGImage(padded, from: padded.extent) {
            return result
        }
        return image // 如果转换失败，回退到原图
    }

    private struct TileInfo { let x: Int; let y: Int; let width: Int; let height: Int }

    private func calculateTiles(width: Int, height: Int, tileSize: Int, overlap: Int) -> [TileInfo] {
        var tiles: [TileInfo] = []
        let step = max(1, tileSize - overlap)
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let startX = min(x, max(0, width - tileSize))
                let startY = min(y, max(0, height - tileSize))
                tiles.append(TileInfo(x: startX, y: startY, width: min(tileSize, width), height: min(tileSize, height)))
                if x + tileSize >= width { break }
                x += step
            }
            if y + tileSize >= height { break }
            y += step
        }
        return tiles
    }

    private func processTile(image: CGImage, model: MLModel, inputInfo: ModelInputInfo) throws -> CGImage {
        let featureProvider: MLDictionaryFeatureProvider
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else {
            throw InferenceError.tileProcessingFailed("无输入节点")
        }

        if inputInfo.isImageInput {
            let pixelBuffer = try ImageTensorConverter.createPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height, pixelFormat: kCVPixelFormatType_32BGRA)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        } else {
            // ⭐️ 修复 3：移除强制解包
            guard let constraint = model.modelDescription.inputDescriptionsByName[inputName]?.multiArrayConstraint else {
                throw InferenceError.tileProcessingFailed("缺少输入约束")
            }
            let array = try ImageTensorConverter.imageToMultiArray(image, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        let output = try model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("模型输出无效")
        }

        if let outputBuffer = outputFeature.imageBufferValue {
            let ciOut = CIImage(cvPixelBuffer: outputBuffer)
            // ⭐️ 修复 3：移除强制解包
            guard let cgOut = Self.ciContext.createCGImage(ciOut, from: ciOut.extent) else {
                throw InferenceError.tileProcessingFailed("输出转换失败")
            }
            return cgOut
        } else if let outputArray = outputFeature.multiArrayValue {
            // ⭐️ 修复 2：兼容 4 通道 (RGBA)
            var outIsNCHW = false
            let shape = outputArray.shape.map { $0.intValue }
            if shape.count == 4 {
                if shape[1] == 3 || shape[1] == 4 {
                    outIsNCHW = true
                }
            }
            return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }
}