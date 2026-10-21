// SuperResApp/Services/SuperResolver.swift
// 超分推理引擎：分块推理、羽化融合、进度回调、SinSR 三件套支持

import Foundation
import CoreML
import CoreImage
import UIKit

/// 超分推理引擎
actor SuperResolver {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    private var isCancelled = false
    private init() {}

    // MARK: - 公共接口
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
                tileSize: tileSize, startTime: startTime,
                progressHandler: progressHandler
            )
        }

        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: descriptor.primaryComputeUnits
        )

        let tiles = calculateTiles(
            width: image.width, height: image.height,
            tileSize: tileSize, overlap: descriptor.overlapPixels
        )
        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        guard let outputContext = createOutputContext(
            width: outputWidth, height: outputHeight
        ) else { throw InferenceError.outputCreationFailed }

        for (index, tile) in tiles.enumerated() {
            if isCancelled { throw InferenceError.cancelled }

            let elapsed = Date().timeIntervalSince(startTime)
            progressHandler?(InferenceProgress(
                currentTile: index + 1,
                totalTiles: totalTiles,
                fraction: Double(index) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(
                    elapsed: elapsed, completed: index, total: totalTiles
                )
            ))

            do {
                let outputTile = try processTile(
                    image: image, tile: tile,
                    model: model, descriptor: descriptor
                )
                autoreleasepool {
                    blendTile(
                        context: outputContext,
                        tile: outputTile,
                        tileRect: tile,
                        scaleFactor: descriptor.scaleFactor,
                        overlap: descriptor.outputOverlapPixels
                    )
                }
            } catch {
                if case InferenceError.insufficientMemory = error,
                   tileSize > descriptor.fallbackTileSize {
                    NSLog("分块 \(tileSize) 内存不足，降级到 \(descriptor.fallbackTileSize) 重试")
                    return try await upscale(
                        image: image, modelID: modelID,
                        tileSize: descriptor.fallbackTileSize,
                        progressHandler: progressHandler
                    )
                }
                throw InferenceError.tileProcessingFailed(error.localizedDescription)
            }
        }

        guard let outputImage = outputContext.makeImage() else {
            throw InferenceError.outputCreationFailed
        }

        let elapsed = Date().timeIntervalSince(startTime)
        progressHandler?(InferenceProgress(
            currentTile: totalTiles, totalTiles: totalTiles,
            fraction: 1.0, elapsedSeconds: elapsed,
            estimatedRemainingSeconds: 0
        ))

        return InferenceResult(
            outputImage: outputImage,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: tileSize, totalTiles: totalTiles
        )
    }

    // MARK: - SinSR 推理
    private func upscaleSinSR(
        image: CGImage, descriptor: ModelDescriptor,
        tileSize: Int, startTime: Date,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        let (encoder, decoder, denoiser) = try await modelStore.loadSinSR()
        let tiles = calculateTiles(
            width: image.width, height: image.height,
            tileSize: tileSize, overlap: descriptor.overlapPixels
        )
        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        guard let outputContext = createOutputContext(
            width: outputWidth, height: outputHeight
        ) else { throw InferenceError.outputCreationFailed }

        for (index, tile) in tiles.enumerated() {
            if isCancelled { throw InferenceError.cancelled }

            let elapsed = Date().timeIntervalSince(startTime)
            progressHandler?(InferenceProgress(
                currentTile: index + 1, totalTiles: totalTiles,
                fraction: Double(index) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(
                    elapsed: elapsed, completed: index, total: totalTiles
                )
            ))

            let outputTile = try autoreleasepool { () -> CGImage in
                guard let inputTile = cropImage(image, to: tile) else {
                    throw InferenceError.tileProcessingFailed("裁剪失败")
                }
                let latent = try runModel(encoder, inputImage: inputTile, outputName: nil)
                let denoised = try runModel(denoiser, inputImage: latent, outputName: nil)
                return try runModel(decoder, inputImage: denoised, outputName: nil)
            }

            autoreleasepool {
                blendTile(
                    context: outputContext, tile: outputTile,
                    tileRect: tile, scaleFactor: descriptor.scaleFactor,
                    overlap: descriptor.outputOverlapPixels
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
            elapsedSeconds: elapsed, modelID: "sinsr",
            tileSize: tileSize, totalTiles: totalTiles
        )
    }

    // MARK: - 分块计算
    struct TileRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private func calculateTiles(
        width: Int, height: Int,
        tileSize: Int, overlap: Int
    ) -> [TileRect] {
        var tiles: [TileRect] = []
        let step = tileSize - overlap
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let tileWidth = min(tileSize, width - x + (x > 0 ? overlap : 0))
                let tileHeight = min(tileSize, height - y + (y > 0 ? overlap : 0))
                tiles.append(TileRect(x: x, y: y, width: tileWidth, height: tileHeight))
                x += step
                if x >= width { break }
            }
            y += step
            if y >= height { break }
        }
        return tiles
    }

    // MARK: - 单块推理（核心修复：支持 MLMultiArray 输入/输出）
    private func processTile(
        image: CGImage, tile: TileRect,
        model: MLModel, descriptor: ModelDescriptor
    ) throws -> CGImage {
        try autoreleasepool {
            guard let inputTile = cropImage(image, to: tile) else {
                throw InferenceError.tileProcessingFailed("裁剪失败")
            }

            // 动态获取模型输入描述
            guard let inputDescription = model.modelDescription
                .inputDescriptionsByName.first else {
                throw InferenceError.tileProcessingFailed("模型无输入")
            }
            let inputName = inputDescription.key

            // === 核心修复：根据模型实际输入类型选择转换方式 ===
            let featureProvider: MLDictionaryFeatureProvider

            if inputDescription.type == .multiArray {
                // Real-ESRGAN 等模型：需要 MLMultiArray (Float32, [1,3,H,W], [0,1])
                let constraint = inputDescription.multiArrayConstraint!
                let shape = constraint.shape // [1, 3, H, W]
                let height = shape[2].intValue
                let width = shape[3].intValue

                // 将 CGImage 缩放到模型要求的尺寸
                let resizedImage = try resizeImage(inputTile, width: width, height: height)

                // CGImage -> MLMultiArray (CHW 格式，归一化到 [0,1])
                let multiArray = try imageToMultiArray(
                    resizedImage, width: width, height: height,
                    dataType: constraint.dataType
                )
                let featureValue = MLFeatureValue(multiArray: multiArray)
                featureProvider = try MLDictionaryFeatureProvider(
                    dictionary: [inputName: featureValue]
                )
            } else if inputDescription.type == .image {
                // 传统图像输入模型
                let constraint = inputDescription.imageConstraint!
                let pixelBuffer = try createPixelBuffer(
                    from: inputTile,
                    width: constraint.pixelsWide,
                    height: constraint.pixelsHigh,
                    pixelFormat: constraint.pixelFormatType
                )
                let imageValue = MLFeatureValue(pixelBuffer: pixelBuffer)
                featureProvider = try MLDictionaryFeatureProvider(
                    dictionary: [inputName: imageValue]
                )
            } else {
                throw InferenceError.tileProcessingFailed(
                    "不支持的输入类型: \(inputDescription.type.rawValue)"
                )
            }

            // 推理
            let output = try model.prediction(from: featureProvider)

            // === 核心修复：根据模型实际输出类型选择转换方式 ===
            guard let outputName = output.featureNames.first,
                  let outputFeature = output.featureValue(for: outputName) else {
                throw InferenceError.tileProcessingFailed("模型输出无效")
            }

            if outputFeature.type == .multiArray,
               let outputArray = outputFeature.multiArrayValue {
                // MLMultiArray -> CGImage
                return try multiArrayToImage(outputArray, scaleFactor: descriptor.scaleFactor)
            } else if outputFeature.type == .image,
                      let outputBuffer = outputFeature.imageBufferValue {
                return try createCGImage(from: outputBuffer)
            }

            throw InferenceError.tileProcessingFailed("输出格式不支持")
        }
    }

    // MARK: - MLMultiArray 转换（核心修复）
    /// CGImage -> MLMultiArray (1, 3, H, W)，Float32，值归一化到 [0, 1]
    private func imageToMultiArray(
        _ image: CGImage, width: Int, height: Int,
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: dataType
        )

        // 提取像素数据（RGBA）
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        // 填充 MLMultiArray（CHW 格式）
        let ptr = array.dataPointer.assumingMemoryBound(to: Float.self)
        let channelStride = height * width

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0
                let spatialIndex = y * width + x
                ptr[0 * channelStride + spatialIndex] = r
                ptr[1 * channelStride + spatialIndex] = g
                ptr[2 * channelStride + spatialIndex] = b
            }
        }

        return array
    }

    /// MLMultiArray -> CGImage（反归一化 [0,1] -> [0,255]，CHW 格式）
    private func multiArrayToImage(
        _ array: MLMultiArray, scaleFactor: Int
    ) throws -> CGImage {
        let shape = array.shape // [1, 3, H, W]
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
                let r = UInt8(clamping: Int((ptr[0 * channelStride + spatialIndex] * 255.0).rounded()))
                let g = UInt8(clamping: Int((ptr[1 * channelStride + spatialIndex] * 255.0).rounded()))
                let b = UInt8(clamping: Int((ptr[2 * channelStride + spatialIndex] * 255.0).rounded()))
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                pixelData[pixelIndex] = r
                pixelData[pixelIndex + 1] = g
                pixelData[pixelIndex + 2] = b
                pixelData[pixelIndex + 3] = 255
            }
        }

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }

        guard let outputImage = context.makeImage() else {
            throw InferenceError.tileProcessingFailed("创建输出 CGImage 失败")
        }
        return outputImage
    }

    // MARK: - 图像处理工具
    private func resizeImage(_ image: CGImage, width: Int, height: Int) throws -> CGImage {
        guard let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw InferenceError.tileProcessingFailed("创建缩放 Context 失败")
        }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let resized = context.makeImage() else {
            throw InferenceError.tileProcessingFailed("缩放失败")
        }
        return resized
    }

    private func cropImage(_ image: CGImage, to rect: TileRect) -> CGImage? {
        let cropRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        return image.cropping(to: cropRect)
    }

    private func createPixelBuffer(
        from image: CGImage, width: Int, height: Int, pixelFormat: OSType
    ) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault, width, height,
            pixelFormat, attributes as CFDictionary, &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw InferenceError.tileProcessingFailed("创建 PixelBuffer 失败")
        }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        )
        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    private func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace, bitmapInfo: bitmapInfo
        ) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        guard let image = context.makeImage() else {
            throw InferenceError.tileProcessingFailed("创建 CGImage 失败")
        }
        return image
    }

    private func createOutputContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        return CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace, bitmapInfo: bitmapInfo
        )
    }

    // MARK: - 羽化融合
    private func blendTile(
        context: CGContext, tile: CGImage,
        tileRect: TileRect, scaleFactor: Int, overlap: Int
    ) {
        let outputX = tileRect.x * scaleFactor
        let outputY = tileRect.y * scaleFactor
        let outputWidth = tileRect.width * scaleFactor
        let outputHeight = tileRect.height * scaleFactor
        let destRect = CGRect(
            x: outputX, y: outputY,
            width: outputWidth, height: outputHeight
        )

        if tileRect.x == 0 && tileRect.y == 0 {
            context.draw(tile, in: destRect)
            return
        }

        let maskWidth = outputWidth
        let maskHeight = outputHeight
        var maskData = [UInt8](repeating: 255, count: maskWidth * maskHeight)
        let featherWidth = min(overlap, outputWidth / 4)
        let featherHeight = min(overlap, outputHeight / 4)

        // 左侧羽化
        if tileRect.x > 0 && featherWidth > 0 {
            for x in 0..<featherWidth {
                let alpha = UInt8(255.0 * Float(x) / Float(featherWidth))
                for y in 0..<maskHeight {
                    maskData[y * maskWidth + x] = alpha
                }
            }
        }

        // 右侧羽化
        if tileRect.x + tileRect.width < tileRect.width + tileRect.x + tileRect.width && featherWidth > 0 {
            // 简化：不处理右侧（由下一块的左侧羽化负责）
        }

        // 顶部羽化
        if tileRect.y > 0 && featherHeight > 0 {
            for y in 0..<featherHeight {
                let alpha = UInt8(255.0 * Float(y) / Float(featherHeight))
                for x in 0..<maskWidth {
                    maskData[y * maskWidth + x] = min(maskData[y * maskWidth + x], alpha)
                }
            }
        }

        // 创建遮罩图像
        let maskColorSpace = CGColorSpaceCreateDeviceGray()
        guard let maskProvider = CGDataProvider(
            data: NSData(bytes: maskData, length: maskData.count)
        ),
              let maskImage = CGImage(
                width: maskWidth, height: maskHeight,
                bitsPerComponent: 8, bitsPerPixel: 8,
                bytesPerRow: maskWidth,
                space: maskColorSpace,
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: maskProvider,
                decode: nil, shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            context.draw(tile, in: destRect)
            return
        }

        // 用遮罩绘制
        context.saveGState()
        context.clip(to: destRect, mask: maskImage)
        context.draw(tile, in: destRect)
        context.restoreGState()
    }

    // MARK: - 辅助
    private func estimateRemaining(
        elapsed: TimeInterval, completed: Int, total: Int
    ) -> TimeInterval? {
        guard completed > 0 else { return nil }
        let perTile = elapsed / Double(completed)
        return perTile * Double(total - completed)
    }
}
