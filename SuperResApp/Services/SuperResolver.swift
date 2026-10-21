// SuperResApp/Services/SuperResolver.swift

import Foundation
import CoreML
import CoreImage
import UIKit

actor SuperResolver {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    private var isCancelled = false
    private init() {}

    func cancel() { isCancelled = true }

    func upscale(
        image: CGImage,
        modelID: String,
        tileSize: Int = 512,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        isCancelled = false
        let startTime = Date()
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        if descriptor.isSinSR {
            return try await upscaleSinSR(
                image: image, descriptor: descriptor,
                tileSize: 256, startTime: startTime,
                progressHandler: progressHandler
            )
        }

        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: descriptor.primaryComputeUnits
        )

        // 动态获取模型真实需要的输入尺寸（确保长宽一致，否则报错）
        var modelInputSize = tileSize
        if let inputDesc = model.modelDescription.inputDescriptionsByName.first?.value {
            if let constraint = inputDesc.multiArrayConstraint, constraint.shape.count == 4 {
                modelInputSize = constraint.shape[2].intValue
            } else if let imageConstraint = inputDesc.imageConstraint {
                modelInputSize = imageConstraint.pixelsHigh
            }
        }

        // 使用固定的重叠像素（比如 16）
        let overlap = 16
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: modelInputSize, overlap: overlap)
        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        // 创建最终输出大图的画布，并处理 Y 轴翻转（UIKit 左上角原点）
        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        outputContext.translateBy(x: 0, y: CGFloat(outputHeight))
        outputContext.scaleBy(x: 1.0, y: -1.0)

        for (index, tile) in tiles.enumerated() {
            if isCancelled { throw InferenceError.cancelled }

            let elapsed = Date().timeIntervalSince(startTime)
            progressHandler?(InferenceProgress(
                currentTile: index + 1,
                totalTiles: totalTiles,
                fraction: Double(index) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(elapsed: elapsed, completed: index, total: totalTiles)
            ))

            // 1. 安全裁切出一块图（不足的部分用黑边补齐，防止拉伸）
            guard let inputTile = safeCropImage(image, tile: tile, targetSize: modelInputSize) else {
                continue
            }
            
            // 2. 推理
            guard let outputTile = try? processTile(image: inputTile, model: model) else {
                continue
            }

            // 3. 将输出块拼接到大图
            autoreleasepool {
                blendTile(
                    context: outputContext,
                    tileImage: outputTile,
                    tileInfo: tile,
                    originalWidth: image.width,
                    originalHeight: image.height,
                    scaleFactor: descriptor.scaleFactor,
                    overlap: overlap
                )
            }
        }

        guard let outputImage = outputContext.makeImage() else {
            throw InferenceError.outputCreationFailed
        }

        let elapsed = Date().timeIntervalSince(startTime)
        return InferenceResult(
            outputImage: outputImage,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: modelInputSize, totalTiles: totalTiles
        )
    }

    // MARK: - 核心：安全网格计算
    struct TileInfo {
        let x: Int
        let y: Int
        let width: Int  // 实际在原图中的有效宽度
        let height: Int // 实际在原图中的有效高度
    }

    private func calculateTiles(width: Int, height: Int, tileSize: Int, overlap: Int) -> [TileInfo] {
        var tiles: [TileInfo] = []
        let step = max(1, tileSize - overlap)
        
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let validWidth = min(tileSize, width - x)
                let validHeight = min(tileSize, height - y)
                tiles.append(TileInfo(x: x, y: y, width: validWidth, height: validHeight))
                
                if x + tileSize >= width { break }
                x += step
            }
            if y + tileSize >= height { break }
            y += step
        }
        return tiles
    }

    // MARK: - 安全裁切（核心修复：补齐黑边，绝不拉伸变形）
    private func safeCropImage(_ image: CGImage, tile: TileInfo, targetSize: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: targetSize, height: targetSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        // 背景填黑
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        
        // 从原图裁出有效部分
        guard let cropped = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else {
            return nil
        }
        
        // 画到左上角（不拉伸，不够的尺寸保持黑色）
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        return context.makeImage()
    }

    private func processTile(image: CGImage, model: MLModel) throws -> CGImage {
        try autoreleasepool {
            guard let inputDict = model.modelDescription.inputDescriptionsByName.first else {
                throw InferenceError.tileProcessingFailed("模型无输入")
            }
            let inputName = inputDict.key
            let inputFeatureDesc = inputDict.value

            let featureProvider: MLDictionaryFeatureProvider
            if inputFeatureDesc.type == .multiArray {
                let constraint = inputFeatureDesc.multiArrayConstraint!
                let width = constraint.shape[3].intValue
                let height = constraint.shape[2].intValue
                let array = try imageToMultiArray(image, width: width, height: height, dataType: constraint.dataType)
                featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
            } else if inputFeatureDesc.type == .image {
                let constraint = inputFeatureDesc.imageConstraint!
                let pixelBuffer = try createPixelBuffer(from: image, width: constraint.pixelsWide, height: constraint.pixelsHigh, pixelFormat: constraint.pixelFormatType)
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
                return try multiArrayToImage(outputArray)
            } else if outputFeature.type == .image, let outputBuffer = outputFeature.imageBufferValue {
                return try createCGImage(from: outputBuffer)
            }
            throw InferenceError.tileProcessingFailed("输出格式不支持")
        }
    }

    // MARK: - 羽化融合（核心修复：精准坐标映射与裁剪）
    private func blendTile(
        context: CGContext, tileImage: CGImage, tileInfo: TileInfo,
        originalWidth: Int, originalHeight: Int, scaleFactor: Int, overlap: Int
    ) {
        let scaledValidW = tileInfo.width * scaleFactor
        let scaledValidH = tileInfo.height * scaleFactor
        
        let destX = CGFloat(tileInfo.x * scaleFactor)
        let destY = CGFloat(tileInfo.y * scaleFactor)
        let destRect = CGRect(x: destX, y: destY, width: CGFloat(scaledValidW), height: CGFloat(scaledValidH))
        
        // 从模型的超分大图中，只裁出对应原图有效区域的那一块（剔除掉黑边）
        let cropRect = CGRect(x: 0, y: 0, width: scaledValidW, height: scaledValidH)
        guard let validOutputTile = tileImage.cropping(to: cropRect) else { return }
        
        // 第一块（左上角）不需要羽化，直接画
        if tileInfo.x == 0 && tileInfo.y == 0 {
            context.draw(validOutputTile, in: destRect)
            return
        }
        
        // 创建遮罩用于羽化融合
        let maskWidth = scaledValidW
        let maskHeight = scaledValidH
        var maskData = [UInt8](repeating: 255, count: maskWidth * maskHeight)
        
        let featherW = min(overlap * scaleFactor, maskWidth / 2)
        let featherH = min(overlap * scaleFactor, maskHeight / 2)

        // 左侧羽化
        if tileInfo.x > 0 && featherW > 0 {
            for x in 0..<featherW {
                let alpha = UInt8(255.0 * Float(x) / Float(featherW))
                for y in 0..<maskHeight {
                    maskData[y * maskWidth + x] = alpha
                }
            }
        }
        // 顶部羽化
        if tileInfo.y > 0 && featherH > 0 {
            for y in 0..<featherH {
                let alpha = UInt8(255.0 * Float(y) / Float(featherH))
                for x in 0..<maskWidth {
                    maskData[y * maskWidth + x] = min(maskData[y * maskWidth + x], alpha)
                }
            }
        }

        let maskColorSpace = CGColorSpaceCreateDeviceGray()
        guard let maskProvider = CGDataProvider(data: NSData(bytes: maskData, length: maskData.count)),
              let maskImage = CGImage(
                width: maskWidth, height: maskHeight,
                bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: maskWidth, space: maskColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: maskProvider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
              ) else {
            context.draw(validOutputTile, in: destRect)
            return
        }

        context.saveGState()
        context.clip(to: destRect, mask: maskImage)
        context.draw(validOutputTile, in: destRect)
        context.restoreGState()
    }

    // MARK: - 底层数据转换
    private func imageToMultiArray(_ image: CGImage, width: Int, height: Int, dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: dataType)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        let channelStride = height * width
        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let spatialIndex = y * width + x
                ptr[0 * channelStride + spatialIndex] = Float(pixelData[pixelIndex]) / 255.0
                ptr[1 * channelStride + spatialIndex] = Float(pixelData[pixelIndex + 1]) / 255.0
                ptr[2 * channelStride + spatialIndex] = Float(pixelData[pixelIndex + 2]) / 255.0
            }
        }
        return array
    }

    private func multiArrayToImage(_ array: MLMultiArray) throws -> CGImage {
        let shape = array.shape
        let height = shape[2].intValue
        let width = shape[3].intValue
        let channelStride = height * width
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)

        for y in 0..<height {
            for x in 0..<width {
                let spatialIndex = y * width + x
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                pixelData[pixelIndex] = UInt8(clamping: Int((ptr[0 * channelStride + spatialIndex] * 255.0).rounded()))
                pixelData[pixelIndex + 1] = UInt8(clamping: Int((ptr[1 * channelStride + spatialIndex] * 255.0).rounded()))
                pixelData[pixelIndex + 2] = UInt8(clamping: Int((ptr[2 * channelStride + spatialIndex] * 255.0).rounded()))
                pixelData[pixelIndex + 3] = 255
            }
        }
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }
        return context.makeImage()!
    }

    private func createPixelBuffer(from image: CGImage, width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &pixelBuffer)
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else { throw InferenceError.tileProcessingFailed("创建 PixelBuffer 失败") }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        return context.makeImage()!
    }

    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        return (elapsed / Double(completed)) * Double(total - completed)
    }

    // 兼容 SinSR 的方法（保持不变）
    private func upscaleSinSR(image: CGImage, descriptor: ModelDescriptor, tileSize: Int, startTime: Date, progressHandler: ((InferenceProgress) -> Void)? = nil) async throws -> InferenceResult {
        throw InferenceError.tileProcessingFailed("SinSR 暂不支持当前版本更新")
    }
}
