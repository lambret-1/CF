// SuperResApp/Services/SuperResolutio/Engines/PiperSREngine.swift

import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct PiperSREngine: SuperResolutionEngine {
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

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
        let canvasRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)

        // ⭐️ 核心改变：直接创建一个透明的 CIImage 画布，绝对不碰 CGContext
        var finalCIImage = CIImage(color: CIColor.clear).cropped(to: canvasRect)
        let sourceCIImage = CIImage(cgImage: image)

        for (index, tile) in tiles.enumerated() {
            try autoreleasepool {
                // 1. CIImage 原生裁剪（左上角坐标系转换）
                let ciY = CGFloat(image.height) - CGFloat(tile.y) - CGFloat(tile.height)
                let ciCropRect = CGRect(x: tile.x, y: Int(ciY), width: tile.width, height: tile.height)
                
                let croppedCIImage = sourceCIImage.cropped(to: ciCropRect)
                let movedCIImage = croppedCIImage.transformed(by: CGAffineTransform(translationX: -ciCropRect.origin.x, y: -ciCropRect.origin.y))
                
                guard let croppedCG = self.ciContext.createCGImage(movedCIImage, from: CGRect(x: 0, y: 0, width: tile.width, height: tile.height)) else { return }
                
                // 2. 模型推理
                let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
                
                // 3. 转回 CIImage 并放缩到目标尺寸
                var ciTile = CIImage(cgImage: outputTile)
                let scaleX = CGFloat(tile.width * scaleFactor) / ciTile.extent.width
                let scaleY = CGFloat(tile.height * scaleFactor) / ciTile.extent.height
                ciTile = ciTile.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
                // 4. 计算目标位置（CIImage 左下角原点）
                let destX = CGFloat(tile.x) * CGFloat(scaleFactor)
                let destY = CGFloat(outputHeight) - CGFloat(tile.y + tile.height) * CGFloat(scaleFactor)
                
                // 5. 移动并叠加（绝对精准，无插值撕裂）
                let positionedTile = ciTile.transformed(by: CGAffineTransform(translationX: destX, y: destY))
                
                // ⭐️ 如果你发现 PiperSR 拼出来是倒的，就在这里翻转单块图。如果是正的，就保持原样。
                // 如果之前是倒的，说明模型本身输出是反的。
                // let flippedTile = positionedTile.transformed(by: CGAffineTransform(scaleX: 1, y: -1).translatedBy(x: 0, y: -positionedTile.extent.height))
                // finalCIImage = flippedTile.composited(over: finalCIImage)
                
                finalCIImage = positionedTile.composited(over: finalCIImage)
            }
            
            let elapsed = Date().timeIntervalSince(startTime)
            progressHandler?(InferenceProgress(
                currentTile: index + 1, totalTiles: totalTiles, fraction: Double(index + 1) / Double(totalTiles),
                elapsedSeconds: elapsed, estimatedRemainingSeconds: (elapsed / Double(index + 1)) * Double(totalTiles - index - 1)
            ))
        }

        guard let finalOutput = ciContext.createCGImage(finalCIImage, from: canvasRect) else {
            throw InferenceError.outputCreationFailed
        }
        return finalOutput
    }

    private struct TileInfo { let x: Int; let y: Int; let width: Int; let height:看着 Int }

    private func calculateTiles(width: Int, height:， Int, tileSize: Int, overlap: Int) -> [TileInfo] {
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
            let ciOut = CIImage(cvPixelBuffer: outputBuffer)
            return ciContext.createCGImage(ciOut, from: ciOut.extent)!
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape[1].intValue == 3
            return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }
}