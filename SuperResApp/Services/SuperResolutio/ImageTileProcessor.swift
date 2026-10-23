import Foundation
import CoreML
import UIKit

/// 处理图片切块与单块推理
struct ImageTileProcessor {
    
    struct TileInfo {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    
    /// 计算切块位置（修复了边缘越界补黑边的问题）
    static func calculateTiles(width: Int, height: Int, tileSize: Int, overlap: Int) -> [TileInfo] {
        var tiles: [TileInfo] = []
        let step = max(1, tileSize - overlap)
        
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                // 核心：保证切出的块，起点不会超过边界
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
    
    /// 从原图中裁切出一块，并补齐到模型要求的尺寸
    static func cropTile(from image: CGImage, tile: TileInfo, targetSize: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: targetSize, height: targetSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        context.translateBy(x: 0, y: CGFloat(targetSize))
        context.scaleBy(x: 1.0, y: -1.0)
        
        guard let cropped = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else {
            return nil
        }
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        return context.makeImage()
    }
    
    /// 执行单次模型推理
    static func processTile(image: CGImage, model: MLModel, isNCHW: Bool) throws -> CGImage {
        try autoreleasepool {
            guard let inputDict = model.modelDescription.inputDescriptionsByName.first else {
                throw InferenceError.tileProcessingFailed("模型无输入")
            }
            let inputName = inputDict.key
            let inputFeatureDesc = inputDict.value

            let featureProvider: MLDictionaryFeatureProvider
            if inputFeatureDesc.type == .multiArray {
                let constraint = inputFeatureDesc.multiArrayConstraint!
                let array = try ImageTensorConverter.imageToMultiArray(image, constraint: constraint, isNCHW: isNCHW)
                featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
            } else if inputFeatureDesc.type == .image {
                let constraint = inputFeatureDesc.imageConstraint!
                let pixelBuffer = try ImageTensorConverter.createPixelBuffer(from: image, width: constraint.pixelsWide, height: constraint.pixelsHigh, pixelFormat: constraint.pixelFormatType)
                featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
            } else {
                throw InferenceError.tileProcessingFailed("不支持的输入类型")
            }

            let output = try model.prediction(from: featureProvider)
            guard let outputName = output.featureNames.first,
                  let outputFeature = output.featureValue(for: outputName) else {
                throw InferenceError.tileProcessingFailed("模型输出无效")
            }

            if outputFeature.type == .multiArray, let outputArray = outputFeature.multiArrayValue {
                let outputShape = outputArray.shape.map { $0.intValue }
                var outputIsNCHW = false
                if outputShape.count == 4 {
                    if outputShape[1] == 3 { outputIsNCHW = true }
                    else if outputShape[3] == 3 { outputIsNCHW = false }
                }
                return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outputIsNCHW)
            } else if outputFeature.type == .image, let outputBuffer = outputFeature.imageBufferValue {
                return try ImageTensorConverter.createCGImage(from: outputBuffer)
            }
            throw InferenceError.tileProcessingFailed("输出格式不支持")
        }
    }
}