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

        // ⭐️ 创建纯净画布，保持系统默认（左下角原点）
        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        for (index, tile) in tiles.enumerated() {
            try autoreleasepool {
                // 1. 原生裁剪（左上角原点）
                let cropRect = CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)
                guard let croppedCG = image.cropping(to: cropRect) else { return }
                
                // 2. 模型推理
                var outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
                
                // 3. 如果是 PiperSR，单块推理结果是倒置的，这里进行翻转
                if modelID == "piper-sr-2x" {
                    if let context = CGContext(data: nil, width: outputTile.width, height: outputTile.height, bitsPerComponent: 8, bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                        context.translateBy(x: 0, y: CGFloat(outputTile.height))
                        context.scaleBy(x: 1.0, y: -1.0)
                        context.draw(outputTile, in: CGRect(x: 0, y: 0, width: outputTile.width, height: outputTile.height))
                        if let flipped = context.makeImage() {
                            outputTile = flipped
                        }
                    }
                }
                
                // 4. 计算尺寸和目标位置
                let drawWidth = CGFloat(tile.width) * CGFloat(scaleFactor)
                let drawHeight = CGFloat(tile.height) * CGFloat(scaleFactor)
                let destX = CGFloat(tile.x) * CGFloat(scaleFactor)
                let destY = CGFloat(tile.y) * CGFloat(scaleFactor)
                
                // ⭐️ 核心数学计算：因为 outputContext 原点在左下角，而 destY 是左上角的坐标，需要换算一下
                let cgY = CGFloat(outputHeight) - destY - drawHeight
                
                let safeWidth = min(Int(drawWidth), outputTile.width)
                let safeHeight = min(Int(drawHeight), outputTile.height)
                
                if let validTile = outputTile.cropping(to: CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)) {
                    // 5. 直接画图，不偏移、不翻转 Context，系统会自动处理好方向
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
            let ciOut = CIImage(cvPixelBuffer: outputBuffer)
            return ciContext.createCGImage(ciOut, from: ciOut.extent)!
        } else if let outputArray = outputFeature.multiArrayValue {
            let outIsNCHW = outputArray.shape[1].intValue == 3
            return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outIsNCHW)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }
}