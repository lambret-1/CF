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
        modelID: String, // ⭐️ 确保有这行
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
            data: nil, width: outputWidth, height: outputHeight, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        outputContext.translateBy(x: 0, y: CGFloat(outputHeight))
        outputContext.scaleBy(x: 1.0, y: -1.0)

        let ciImage = CIImage(cgImage: image)
        
        for (index, tile) in tiles.enumerated() {
            let cropRect = CGRect(x: tile.x, y: tile.y, width: tileSize, height: tileSize)
            let croppedCIImage = ciImage.cropped(to: cropRect)
            let movedCIImage = croppedCIImage.transformed(by: CGAffineTransform(translationX: -cropRect.origin.x, y: -cropRect.origin.y))
            
            guard let croppedCG = self.ciContext.createCGImage(movedCIImage, from: CGRect(x: 0, y: 0, width: tileSize, height: tileSize)) else { continue }
            
            let outputTile = try self.processTile(image: croppedCG, model: model, inputInfo: inputInfo)
            self.blendTile(context: outputContext, tileImage: outputTile, tileInfo: tile, scaleFactor: scaleFactor, overlap: overlap)
            
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

    private func blendTile(context: CGContext, tileImage: CGImage, tileInfo: TileInfo, scaleFactor: Int, overlap: Int) {
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
}