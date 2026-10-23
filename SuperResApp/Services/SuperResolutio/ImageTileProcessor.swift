import Foundation
import CoreML
import UIKit
import CoreImage // ⭐️ 引入 CoreImage 用于高效边缘拉伸填充

/// 处理图片切块与单块推理
struct ImageTileProcessor {
    
    // ⭐️ 静态 CIContext，复用上下文，避免循环中重复初始化造成极大的性能损耗
    private static let ciContext = CIContext(options: [.workingColorSpace: NSNull()])
    
    struct TileInfo {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }
    
    /// 计算切块位置
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
    
    /// 从原图中裁切出一块，并补齐到模型要求的尺寸（使用边缘拉伸代替纯黑，避免光晕）
    static func cropTile(from image: CGImage, tile: TileInfo, targetSize: Int) -> CGImage? {
        guard let cropped = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else {
            return nil
        }
        
        // ⭐️ 性能优化：如果本身就是完整尺寸（大部分内部块），直接返回，省去填充开销
        if cropped.width == targetSize && cropped.height == targetSize {
            return cropped
        }
        
        // ⭐️ 画质优化：用 CI 的边缘拉伸代替 CGContext 的纯黑填充
        let ciImage = CIImage(cgImage: cropped)
        let clamped = ciImage.clampedToExtent() // 无限向外拉伸边缘像素
        
        // ⭐️ 坐标对齐：CIImage 原点在左下角。
        // 为了把图像锚定在左上角，并向右下角补齐，我们需要将图像向上平移
        let translateY = CGFloat(targetSize - cropped.height)
        let transform = CGAffineTransform(translationX: 0, y: translateY)
        let shifted = clamped.transformed(by: transform)
        
        // 裁剪出目标大小的画幅
        let cropRect = CGRect(x: 0, y: 0, width: targetSize, height: targetSize)
        let paddedCI = shifted.cropped(to: cropRect)
        
        return ciContext.createCGImage(paddedCI, from: paddedCI.extent)
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
                guard let constraint = inputFeatureDesc.multiArrayConstraint else { // ⭐️ 修复强制解包
                    throw InferenceError.tileProcessingFailed("无多数组约束")
                }
                let array = try ImageTensorConverter.imageToMultiArray(image, constraint: constraint, isNCHW: isNCHW)
                featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
            } else if inputFeatureDesc.type == .image {
                guard let constraint = inputFeatureDesc.imageConstraint else { // ⭐️ 修复强制解包
                    throw InferenceError.tileProcessingFailed("无图像约束")
                }
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
                // ⭐️ 防崩溃修复：增加 4（RGBA）通道支持，防止某些特殊模型触发内存越界
                var outputIsNCHW = false
                let outputShape = outputArray.shape.map { $0.intValue }
                
                if outputShape.count == 4 {
                    if outputShape[1] == 3 || outputShape[1] == 4 { 
                        outputIsNCHW = true 
                    } else if outputShape[3] == 3 || outputShape[3] == 4 { 
                        outputIsNCHW = false 
                    }
                }
                return try ImageTensorConverter.multiArrayToImage(outputArray, isNCHW: outputIsNCHW)
            } else if outputFeature.type == .image, let outputBuffer = outputFeature.imageBufferValue {
                return try ImageTensorConverter.createCGImage(from: outputBuffer)
            }
            throw InferenceError.tileProcessingFailed("输出格式不支持")
        }
    }
}