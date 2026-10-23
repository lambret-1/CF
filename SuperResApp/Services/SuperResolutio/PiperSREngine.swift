// SuperResApp/Services/SuperResolutio/Engines/PiperSREngine.swift

import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct PiperSREngine: SuperResolutionEngine {
    // 128瓦片模型，不需要频繁用CIContext转换，直接走原生CGContext最快最稳
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

        let tileSize = inputInfo.width // PiperSR 是 128
        let overlap = tileSize / 16 
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: tileSize, overlap: overlap)
        let totalTiles = tiles.count
        
        let outputWidth = image.width * scaleFactor
        let outputHeight = image.height * scaleFactor

        // 1. 创建画布，并执行【全局翻转】（让坐标系变成左上角原点）
        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        outputContext.translateBy(x: 0, y: CGFloat(outputHeight))
        outputContext.scaleBy(x: 1.0, y: -1.0)

        for (index, tile) in tiles.enumerated() {
            try autoreleasepool {
                // 2. 原生裁剪
                let cropRect = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
                guard let croppedCG = image.cropping(to: cropRect) else { return }
                
                // 3. 模型推理（128x128 输入的输出是 256x256）
                let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
                
                let drawWidth = CGFloat(tile.width * scaleFactor)
                let drawHeight = CGFloat(tile.height * scaleFactor)
                let destX = CGFloat(tile.x * scaleFactor)
                let destY = CGFloat(tile.y * scaleFactor)
                
                let cropRect2 = CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight)
                guard let validTile = outputTile.cropping(to: cropRect2) else { return }
                
                // 4. ⭐️ 核心修复：回归历史代码的【局部翻转拼接法】
                outputContext.saveGState()
                outputContext.translateBy(x: destX, y: destY + drawHeight)
                outputContext.scaleBy(x: 1.0, y: -1.0)
                outputContext.draw(validTile, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
                outputContext.restoreGState()
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
        guard let inputName = model.modelDescription.inputDescriptionsByName.first?.key else { throw InferenceError.tileProcessingFailed("无输入节点") }

        if inputInfo.isImageInput {
            let pixelBuffer = try ImageTensorConverter.createPixelBuffer(from: image, width: inputInfo.width, height: inputInfo.height, pixelFormat: kCVPixelFormatType_32BGRA)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        } else {
            let constraint = model.modelDescription.inputDescriptionsByName[inputName]!.multiArrayConstraint!
            let array = try ImageTensorConverter.imageToMultiArray(image, constraint: constraint, isNCHW: inputInfo.isNCHW)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        }

        let output = try model.prediction(from: featureProvider)
        guard let outputName = output.featureNames.first, let outputFeature = output.featureValue(for: outputName) else { throw InferenceError.tileProcessingFailed("模型输出无效") }

        if let outputBuffer = outputFeature.imageBufferValue {
            // ⭐️ 只要这里原样转出来，配合上面的局部翻转拼接，就能完美对
            return try ImageTensorConverter.createCGImage(from: outputBuffer)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape[1].intValue == 3
            return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }
}