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

        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: descriptor.primaryComputeUnits
        )

        // 1. 获取模型真正需要的固定尺寸（通常为 256, 512 等）
        var targetSize = tileSize
        if let inputDesc = model.modelDescription.inputDescriptionsByName.first?.value {
            if let constraint = inputDesc.multiArrayConstraint, constraint.shape.count == 4 {
                targetSize = constraint.shape[2].intValue
            } else if let imageConstraint = inputDesc.imageConstraint {
                targetSize = imageConstraint.pixelsHigh
            }
        }

        // 2. 生成网格坐标
        let overlap = 16
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: targetSize, overlap: overlap)
        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        // 3. 创建输出大图（画布原点设为左上角，Y轴向下）
        guard let outputContext = CGContext(
            data: nil, width: outputWidth, height: outputHeight,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.outputCreationFailed }
        
        // 翻转画布坐标系
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

            // 4. 裁剪这一块（不足的部分补黑边，绝对不拉伸）
            guard let inputTile = createTile(from: image, tile: tile, targetSize: targetSize) else {
                continue
            }
            
            // 5. 推理
            guard let outputTile = try? processTile(image: inputTile, model: model) else {
                continue
            }

            // 6. 贴回大图（使用简单重叠覆盖，避免 Mask 引起坐标错乱）
            autoreleasepool {
                blendTile(
                    context: outputContext,
                    tileImage: outputTile,
                    tileInfo: tile,
                    scaleFactor: descriptor.scaleFactor
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
            tileSize: targetSize, totalTiles: totalTiles
        )
    }

    // MARK: - 网格计算
    struct TileInfo {
        let x: Int      // 在原图中的实际起点X
        let y: Int      // 在原图中的实际起点Y
        let width: Int  // 有效宽度（不超过剩余边界）
        let height: Int // 有效高度（不超过剩余边界）
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

    // MARK: - 安全裁切（补齐黑边）
    private func createTile(from image: CGImage, tile: TileInfo, targetSize: Int) -> CGImage? {
        guard let context = CGContext(
            data: nil, width: targetSize, height: targetSize,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        
        context.setFillColor(UIColor.black.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: targetSize, height: targetSize))
        
        // 翻转 Context，让我们可以直接用左上角坐标系进行绘制
        context.translateBy(x: 0, y: CGFloat(targetSize))
        context.scaleBy(x: 1.0, y: -1.0)
        
        // 从原图裁出有效部分
        guard let cropped = image.cropping(to: CGRect(x: tile.x, y: tile.y, width: tile.width, height: tile.height)) else {
            return nil
        }
        
        // 画到左上角
        context.draw(cropped, in: CGRect(x: 0, y: 0, width: tile.width, height: tile.height))
        return context.makeImage()
    }

    // MARK: - 模型推理
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

    // MARK: - 拼接（去掉 Mask，直接覆盖重叠区，防止坐标错位）
    private func blendTile(context: CGContext, tileImage: CGImage, tileInfo: TileInfo, scaleFactor: Int) {
        // 我们要画多大（不含补边的区域）
        let drawWidth = CGFloat(tileInfo.width * scaleFactor)
        let drawHeight = CGFloat(tileInfo.height * scaleFactor)
        
        // 在原图中的最终位置
        let destX = CGFloat(tileInfo.x * scaleFactor)
        let destY = CGFloat(tileInfo.y * scaleFactor)
        
        // 从超分结果中，截取真正有效的部分（去掉右下角的补边黑块）
        let cropRect = CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight)
        guard let validTile = tileImage.cropping(to: cropRect) else { return }
        
        context.saveGState()
        // 核心：标准的“在左上角坐标系中绘制不翻转图片”的写法
        context.translateBy(x: destX, y: destY + drawHeight)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(validTile, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
        context.restoreGState()
    }

    // MARK: - 底层数据转换（核心修复：确保像素与 Context 坐标对齐）
    private func imageToMultiArray(_ image: CGImage, width: Int, height: Int, dataType: MLMultiArrayDataType) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: height), NSNumber(value: width)], dataType: dataType)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        
        // 翻转，保证绘制进去时不颠倒
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
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
        // 翻转 Context，让输出的图片是正向的
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        
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
        
        context?.translateBy(x: 0, y: CGFloat(height))
        context?.scaleBy(x: 1.0, y: -1.0)
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer), width: CVPixelBufferGetWidth(pixelBuffer), height: CVPixelBufferGetHeight(pixelBuffer), bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        context.translateBy(x: 0, y: CGFloat(CVPixelBufferGetHeight(pixelBuffer)))
        context.scaleBy(x: 1.0, y: -1.0)
        
        return context.makeImage()!
    }

    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        return (elapsed / Double(completed)) * Double(total - completed)
    }
}
