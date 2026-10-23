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
        let overlap = tileSize / 16 
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: tileSize, overlap: overlap)
        let totalTiles = tiles.count
        
        let outputWidth = image.width * scaleFactor
        let outputHeight = image.height * scaleFactor

        // ⭐️ 纯净版画布：去掉所有内存限制和缩放，老老实实按 4 倍出图
        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        outputContext.translateBy(x: 0, y: CGFloat(outputHeight))
        outputContext.scaleBy(x: 1.0, y: -1.0)

        let ciImage = CIImage(cgImage: image)
        
        for (index, tile) in tiles.enumerated() {
            try autoreleasepool {
                // ⭐️ 修复：使用 CoreImage 的坐标系裁剪，但要把 Y 轴翻过来
                // CIImage 原点在左下角，我们的 tile.y 是左上角，所以要换算一下
                let ciY = CGFloat(image.height) - CGFloat(tile.y) - CGFloat(tile.height)
                let ciCropRect = CGRect(x: tile.x, y: Int(ciY), width: tile.width, height: tile.height)
                
                let croppedCIImage = ciImage.cropped(to: ciCropRect)
                let movedCIImage = croppedCIImage.transformed(by: CGAffineTransform(translationX: -ciCropRect.origin.x, y: -ciCropRect.origin.y))
                
                guard let croppedCG = self.ciContext.createCGImage(movedCIImage, from: CGRect(x: 0, y: 0, width: tile.width, height: tile.height)) else { return }
                
                let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
                
                // 计算绘制尺寸
                let drawWidth = CGFloat(tile.width) * CGFloat(scaleFactor)
                let drawHeight = CGFloat(tile.height) * CGFloat(scaleFactor)
                let destX = CGFloat(tile.x) * CGFloat(scaleFactor)
                let destY = CGFloat(tile.y) * CGFloat(scaleFactor)
                
                let safeWidth = min(Int(drawWidth), outputTile.width)
                let safeHeight = min(Int(drawHeight), outputTile.height)
                
                if let validTile = outputTile.cropping(to: CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)) {
                    outputContext.saveGState()
                    // ⭐️ 极简精准拼接
                    outputContext.translateBy(x: destX, y: destY + drawHeight)
                    outputContext.scaleBy(x: 1.0, y: -1.0)
                    outputContext.draw(validTile, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
                    outputContext.restoreGState()
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
            return try ImageTensorConverter.createCGImage(from: outputBuffer)
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape[1].intValue == 3
            return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }
}