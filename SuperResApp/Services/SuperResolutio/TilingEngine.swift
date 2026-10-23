// SuperResApp/Services/SuperResolutio/Engines/TilingEngine.swift

import Foundation
import CoreML
import UIKit
import CoreVideo
import CoreImage

struct TilingEngine: SuperResolutionEngine {
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
        let overlap = tileSize / 16 // 小小的重叠，防止接缝
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: tileSize, overlap: overlap)
        let totalTiles = tiles.count
        
        let outputWidth = image.width * scaleFactor
        let outputHeight = image.height * scaleFactor
        let canvasRect = CGRect(x: 0, y: 0, width: outputWidth, height: outputHeight)

        // 1. 创建一个完全透明的画布
        var finalCIImage = CIImage(color: .clear).cropped(to: canvasRect)
        let sourceCIImage = CIImage(cgImage: image)

        for (index, tile) in tiles.enumerated() {
            try autoreleasepool {
                // 2. CIImage 的坐标系原点在左下角，所以 Y 轴要换算一下
                let ciY = CGFloat(image.height) - CGFloat(tile.y) - CGFloat(tile.height)
                let ciCropRect = CGRect(x: tile.x, y: Int(ciY), width: tile.width, height: tile.height)
                
                // 3. 极简裁剪，绝不越界
                let croppedCIImage = sourceCIImage.cropped(to: ciCropRect)
                let movedCIImage = croppedCIImage.transformed(by: CGAffineTransform(translationX: -ciCropRect.origin.x, y: -ciCropRect.origin.y))
                
                guard let croppedCG = self.ciContext.createCGImage(movedCIImage, from: CGRect(x: 0, y: 0, width: tile.width, height: tile.height)) else { return }
                
                // 4. 推理
                let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
                
                // 5. 缩放并对齐到画布
                var tileCIImage = CIImage(cgImage: outputTile)
                
                // 因为模型输出尺寸可能跟 tile 尺寸有细微区别，我们需要先把它缩放成切块尺寸
                let scaleX = CGFloat(tile.width) / tileCIImage.extent.width
                let scaleY = CGFloat(tile.height) / tileCIImage.extent.height
                tileCIImage = tileCIImage.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                
                // 6. 计算在画布上的目标位置 (CIImage 坐标系左下角)
                let destX = CGFloat(tile.x) * CGFloat(scaleFactor)
                let destY = CGFloat(outputHeight) - (CGFloat(tile.y) + CGFloat(tile.height)) * CGFloat(scaleFactor)
                
                // 7. 移动并放大到最终位置
                let transformedTile = tileCIImage
                    .transformed(by: CGAffineTransform(scaleX: CGFloat(scaleFactor), y: CGFloat(scaleFactor)))
                    .transformed(by: CGAffineTransform(translationX: destX, y: destY))
                
                // 8. 叠加到总画布上
                finalCIImage = transformedTile.composited(over: finalCIImage)
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
            // ⭐️ 这里直接用官方标准方法，绝不乱搞翻转
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