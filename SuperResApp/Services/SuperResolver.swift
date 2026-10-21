// SuperResApp/Services/SuperResolver.swift
// 超分推理引擎：分块推理、羽化融合、进度回调、SinSR 三件套支持

import Foundation
import CoreML
import CoreImage
import UIKit

/// 超分推理引擎
actor SuperResolver {
    /// 单例
    static let shared = SuperResolver()

    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared

    /// 取消标记
    private var isCancelled = false

    private init() {}

    // MARK: - 公共接口

    /// 取消当前推理
    func cancel() {
        isCancelled = true
    }

    /// 对图片进行超分推理
    /// - Parameters:
    ///   - image: 输入图片
    ///   - modelID: 模型 id
    ///   - tileSize: 分块大小（输入域），默认 512
    ///   - progressHandler: 进度回调
    /// - Returns: 推理结果
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

        // SinSR 特殊处理
        if descriptor.isSinSR {
            return try await upscaleSinSR(
                image: image,
                descriptor: descriptor,
                tileSize: tileSize,
                startTime: startTime,
                progressHandler: progressHandler
            )
        }

        // 加载模型
        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: descriptor.primaryComputeUnits
        )

        // 计算分块
        let tiles = calculateTiles(
            width: image.width,
            height: image.height,
            tileSize: tileSize,
            overlap: descriptor.overlapPixels
        )

        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        // 创建输出画布
        guard let outputContext = createOutputContext(width: outputWidth, height: outputHeight) else {
            throw InferenceError.outputCreationFailed
        }

        // 逐块推理
        for (index, tile) in tiles.enumerated() {
            if isCancelled {
                throw InferenceError.cancelled
            }

            let elapsed = Date().timeIntervalSince(startTime)
            let progress = InferenceProgress(
                currentTile: index + 1,
                totalTiles: totalTiles,
                fraction: Double(index) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(
                    elapsed: elapsed,
                    completed: index,
                    total: totalTiles
                )
            )
            progressHandler?(progress)

            do {
                let outputTile = try processTile(
                    image: image,
                    tile: tile,
                    model: model,
                    descriptor: descriptor
                )

                // 羽化融合到输出画布
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
                // 如果是内存错误且当前 tileSize > fallback，降级重试
                if case InferenceError.insufficientMemory = error,
                   tileSize > descriptor.fallbackTileSize {
                    NSLog("分块 \(tileSize) 内存不足，降级到 \(descriptor.fallbackTileSize) 重试")
                    return try await upscale(
                        image: image,
                        modelID: modelID,
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
            currentTile: totalTiles,
            totalTiles: totalTiles,
            fraction: 1.0,
            elapsedSeconds: elapsed,
            estimatedRemainingSeconds: 0
        ))

        return InferenceResult(
            outputImage: outputImage,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: outputWidth, height: outputHeight),
            elapsedSeconds: elapsed,
            modelID: modelID,
            tileSize: tileSize,
            totalTiles: totalTiles
        )
    }

    // MARK: - SinSR 推理

    private func upscaleSinSR(
        image: CGImage,
        descriptor: ModelDescriptor,
        tileSize: Int,
        startTime: Date,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        let (encoder, decoder, denoiser) = try await modelStore.loadSinSR()

        let tiles = calculateTiles(
            width: image.width,
            height: image.height,
            tileSize: tileSize,
            overlap: descriptor.overlapPixels
        )

        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        guard let outputContext = createOutputContext(width: outputWidth, height: outputHeight) else {
            throw InferenceError.outputCreationFailed
        }

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

            let outputTile = try autoreleasepool { () -> CGImage in
                // 1. 裁剪输入块
                guard let inputTile = cropImage(image, to: tile) else {
                    throw InferenceError.tileProcessingFailed("裁剪失败")
                }

                // 2. Encoder
                let latent = try runModel(encoder, inputImage: inputTile, outputName: nil)

                // 3. Denoiser (CPU) - 简化为单步去噪
                let denoised = try runModel(denoiser, inputImage: latent, outputName: nil)

                // 4. Decoder
                return try runModel(decoder, inputImage: denoised, outputName: nil)
            }

            autoreleasepool {
                blendTile(
                    context: outputContext,
                    tile: outputTile,
                    tileRect: tile,
                    scaleFactor: descriptor.scaleFactor,
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
            elapsedSeconds: elapsed,
            modelID: "sinsr",
            tileSize: tileSize,
            totalTiles: totalTiles
        )
    }

    // MARK: - 分块计算

    /// 分块矩形
    struct TileRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    /// 计算分块布局（带重叠）
    private func calculateTiles(width: Int, height: Int, tileSize: Int, overlap: Int) -> [TileRect] {
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

    // MARK: - 单块推理

    /// 处理单个分块
    private func processTile(
        image: CGImage,
        tile: TileRect,
        model: MLModel,
        descriptor: ModelDescriptor
    ) throws -> CGImage {
        try autoreleasepool {
            guard let inputTile = cropImage(image, to: tile) else {
                throw InferenceError.tileProcessingFailed("裁剪失败")
            }
            return try runModel(model, inputImage: inputTile, outputName: nil)
        }
    }

    /// 运行 Core ML 模型
    private func runModel(_ model: MLModel, inputImage: CGImage, outputName: String?) throws -> CGImage {
        // 获取模型输入描述
        guard let inputDescription = model.modelDescription.inputDescriptionsByName.values.first,
              let inputName = model.modelDescription.inputDescriptionsByName.keys.first else {
            throw InferenceError.tileProcessingFailed("模型输入描述无效")
        }

        // 创建输入特征
        let featureProvider: MLFeatureProvider
        if inputDescription.type == .image {
            // 图像输入
            let constraint = inputDescription.imageConstraint!
            let pixelBuffer = try createPixelBuffer(
                from: inputImage,
                width: constraint.pixelsWide,
                height: constraint.pixelsHigh,
                pixelFormat: constraint.pixelFormatType
            )
            let imageValue = MLFeatureValue(pixelBuffer: pixelBuffer)
            let dict = [inputName: imageValue]
            featureProvider = try MLDictionaryFeatureProvider(dictionary: dict)
        } else {
            throw InferenceError.tileProcessingFailed("不支持的输入类型")
        }

        // 推理
        let output = try model.prediction(from: featureProvider)

        // 获取输出
        guard let outputName = output.featureNames.first,
              let outputFeature = output.featureValue(for: outputName) else {
            throw InferenceError.tileProcessingFailed("模型输出无效")
        }

        if outputFeature.type == .image, let outputBuffer = outputFeature.imageBufferValue {
            return try createCGImage(from: outputBuffer)
        } else if let outputBuffer = outputFeature.imageBufferValue {
            return try createCGImage(from: outputBuffer)
        }

        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }

    // MARK: - 图像处理工具

    /// 裁剪图片到指定区域
    private func cropImage(_ image: CGImage, to rect: TileRect) -> CGImage? {
        let cropRect = CGRect(x: rect.x, y: rect.y, width: rect.width, height: rect.height)
        return image.cropping(to: cropRect)
    }

    /// 创建 CVPixelBuffer 从 CGImage
    private func createPixelBuffer(from image: CGImage, width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            pixelFormat,
            attributes as CFDictionary,
            &pixelBuffer
        )
        guard status == kCVReturnSuccess, let buffer = pixelBuffer else {
            throw InferenceError.tileProcessingFailed("创建 PixelBuffer 失败")
        }

        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }

        let context = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        )

        context?.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }

    /// 从 CVPixelBuffer 创建 CGImage
    private func createCGImage(from pixelBuffer: CVPixelBuffer) throws -> CGImage {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }

        guard let image = context.makeImage() else {
            throw InferenceError.tileProcessingFailed("创建 CGImage 失败")
        }
        return image
    }

    /// 创建输出画布
    private func createOutputContext(width: Int, height: Int) -> CGContext? {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        return CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        )
    }

    // MARK: - 羽化融合

    /// 将输出块羽化融合到画布
    private func blendTile(
        context: CGContext,
        tile: CGImage,
        tileRect: TileRect,
        scaleFactor: Int,
        overlap: Int
    ) {
        let outputX = tileRect.x * scaleFactor
        let outputY = tileRect.y * scaleFactor
        let outputWidth = tileRect.width * scaleFactor
        let outputHeight = tileRect.height * scaleFactor

        let destRect = CGRect(x: outputX, y: outputY, width: outputWidth, height: outputHeight)

        // 第一块直接绘制，后续块使用羽化混合
        if tileRect.x == 0 && tileRect.y == 0 {
            context.draw(tile, in: destRect)
            return
        }

        // 创建羽化遮罩
        let maskWidth = outputWidth
        let maskHeight = outputHeight
        var maskData = [UInt8](repeating: 255, count: maskWidth * maskHeight)

        let featherWidth = min(overlap, outputWidth / 4)
        let featherHeight = min(overlap, outputHeight / 4)

        // 左侧羽化
        if tileRect.x > 0 && featherWidth > 0 {
            for x in 0..<featherWidth {
                let alpha = UInt8(255 * x / featherWidth)
                for y in 0..<maskHeight {
                    maskData[y * maskWidth + x] = min(maskData[y * maskWidth + x], alpha)
                }
            }
        }

        // 顶部羽化
        if tileRect.y > 0 && featherHeight > 0 {
            for y in 0..<featherHeight {
                let alpha = UInt8(255 * y / featherHeight)
                for x in 0..<maskWidth {
                    maskData[y * maskWidth + x] = min(maskData[y * maskWidth + x], alpha)
                }
            }
        }

        // 创建遮罩图片
        guard let maskDataProvider = CGDataProvider(data: Data(bytes: maskData, count: maskData.count) as CFData),
              let maskImage = CGImage(
                width: maskWidth,
                height: maskHeight,
                bitsPerComponent: 8,
                bitsPerPixel: 8,
                bytesPerRow: maskWidth,
                space: CGColorSpaceCreateDeviceGray(),
                bitmapInfo: CGBitmapInfo(rawValue: 0),
                provider: maskDataProvider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            context.draw(tile, in: destRect)
            return
        }

        context.saveGState()
        context.clip(to: destRect, mask: maskImage)
        context.draw(tile, in: destRect)
        context.restoreGState()
    }

    // MARK: - 工具方法

    /// 估算剩余时间
    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        let perTile = elapsed / Double(completed)
        return perTile * Double(total - completed)
    }
}
