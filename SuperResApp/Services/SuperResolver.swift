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

        // 动态获取模型的输入尺寸限制（比如 PiperSR 可能是 256 或 512）
        var modelInputSize = 512
        if let inputDesc = model.modelDescription.inputDescriptionsByName.first?.value,
           let constraint = inputDesc.multiArrayConstraint,
           constraint.shape.count == 4 {
            modelInputSize = constraint.shape[2].intValue
        } else if let imageConstraint = model.modelDescription.inputDescriptionsByName.first?.value.imageConstraint {
            modelInputSize = imageConstraint.pixelsHigh
        }

        let tiles = calculateTiles(
            width: image.width, height: image.height,
            tileSize: modelInputSize, overlap: descriptor.overlapPixels
        )
        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

        // 创建输出画布（并处理 Y 轴翻转，防止图像上下颠倒）
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
            tileSize: 256, overlap: descriptor.overlapPixels
        )
        let totalTiles = tiles.count
        let outputWidth = image.width * descriptor.scaleFactor
        let outputHeight = image.height * descriptor.scaleFactor

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

    private func runModel(_ model: MLModel, inputImage: CGImage, outputName: String?) throws -> CGImage {
        guard let inputDict = model.modelDescription.inputDescriptionsByName.first else {
            throw InferenceError.tileProcessingFailed("模型无输入")
        }
        let inputName = inputDict.key
        let inputFeatureDesc = inputDict.value

        let featureProvider: MLDictionaryFeatureProvider
        if inputFeatureDesc.type == .multiArray, let constraint = inputFeatureDesc.multiArrayConstraint {
            let shape = constraint.shape
            let height = shape[2].intValue
            let width = shape[3].intValue
            let resizedImage = try resizeImage(inputImage, width: width, height: height)
            let array = try imageToMultiArray(resizedImage, width: width, height: height, dataType: constraint.dataType)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(multiArray: array)])
        } else if inputFeatureDesc.type == .image, let constraint = inputFeatureDesc.imageConstraint {
            let pixelBuffer = try createPixelBuffer(from: inputImage, width: constraint.pixelsWide, height: constraint.pixelsHigh, pixelFormat: constraint.pixelFormatType)
            featureProvider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)])
        } else {
            throw InferenceError.tileProcessingFailed("不支持的输入类型")
        }

        let output = try model.prediction(from: featureProvider)
        let outName = outputName ?? output.featureNames.first!
        
        guard let outFeature = output.featureValue(for: outName) else {
            throw InferenceError.tileProcessingFailed("模型输出无效")
        }

        if outFeature.type == .multiArray, let outArray = outFeature.multiArrayValue {
            return try multiArrayToImage(outArray)
        } else if outFeature.type == .image, let outBuffer = outFeature.imageBufferValue {
            return try createCGImage(from: outBuffer)
        }
        throw InferenceError.tileProcessingFailed("输出格式不支持")
    }

    // MARK: - 分块计算（修复：保证每个切片大小一致且不越界）
    struct TileRect {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
    }

    private func calculateTiles(width: Int, height: Int, tileSize: Int, overlap: Int) -> [TileRect] {
        var tiles: [TileRect] = []
        let step = max(1, tileSize - overlap)
        
        var y = 0
        while y < height {
            var x = 0
            while x < width {
                // 确保最后一块不越界：如果剩余宽度不够，把起点往前挪
                let actualX = (x + tileSize > width) ? max(0, width - tileSize) : x
                let actualY = (y + tileSize > height) ? max(0, height - tileSize) : y
                
                let actualW = min(tileSize, width)
                let actualH = min(tileSize, height)
                
                tiles.append(TileRect(x: actualX, y: actualY, width: actualW, height: actualH))
                
                if x + tileSize >= width { break }
                x += step
            }
            if y + tileSize >= height { break }
            y += step
        }
        return tiles
    }

    // MARK: - 单块推理
    private func processTile(
        image: CGImage, tile: TileRect,
        model: MLModel, descriptor: ModelDescriptor
    ) throws -> CGImage {
        try autoreleasepool {
            guard let inputTile = cropImage(image, to: tile) else {
                throw InferenceError.tileProcessingFailed("裁剪失败")
            }

            guard let inputDict = model.modelDescription.inputDescriptionsByName.first else {
                throw InferenceError.tileProcessingFailed("模型无输入")
            }
            let inputName = inputDict.key
            let inputFeatureDesc = inputDict.value

            let featureProvider: MLDictionaryFeatureProvider

            if inputFeatureDesc.type == .multiArray {
                let constraint = inputFeatureDesc.multiArrayConstraint!
                let shape = constraint.shape
                let modelHeight = shape[2].intValue
                let modelWidth = shape[3].intValue

                // 确保尺寸完全匹配模型输入
                let resizedImage = try resizeImage(inputTile, width: modelWidth, height: modelHeight)
                let multiArray = try imageToMultiArray(
                    resizedImage, width: modelWidth, height: modelHeight,
                    dataType: constraint.dataType
                )
                featureProvider = try MLDictionaryFeatureProvider(
                    dictionary: [inputName: MLFeatureValue(multiArray: multiArray)]
                )
            } else if inputFeatureDesc.type == .image {
                let constraint = inputFeatureDesc.imageConstraint!
                let pixelBuffer = try createPixelBuffer(
                    from: inputTile,
                    width: constraint.pixelsWide,
                    height: constraint.pixelsHigh,
                    pixelFormat: constraint.pixelFormatType
                )
                featureProvider = try MLDictionaryFeatureProvider(
                    dictionary: [inputName: MLFeatureValue(pixelBuffer: pixelBuffer)]
                )
            } else {
                throw InferenceError.tileProcessingFailed("不支持的输入类型")
            }

            let output = try model.prediction(from: featureProvider)
            guard let outputName = output.featureNames.first,
                  let outputFeature = output.featureValue(for: outputName) else {
                throw InferenceError.tileProcessingFailed("模型输出无效")
            }

            if outputFeature.type == .multiArray,
               let outputArray = outputFeature.multiArrayValue {
                return try multiArrayToImage(outputArray)
            } else if outputFeature.type == .image,
                      let outputBuffer = outputFeature.imageBufferValue {
                return try createCGImage(from: outputBuffer)
            }

            throw InferenceError.tileProcessingFailed("输出格式不支持")
        }
    }

    // MARK: - MLMultiArray 转换
    private func imageToMultiArray(
        _ image: CGImage, width: Int, height: Int,
        dataType: MLMultiArrayDataType
    ) throws -> MLMultiArray {
        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: height), NSNumber(value: width)],
            dataType: dataType
        )

        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        let colorSpace = CGColorSpaceCreateDeviceRGB()

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.tileProcessingFailed("创建 CGContext 失败") }
        
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

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

        guard let context = CGContext(
            data: &pixelData, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败") }

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
        ) else { throw InferenceError.tileProcessingFailed("创建缩放 Context 失败") }
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

    private func createPixelBuffer(from image: CGImage, width: Int, height: Int, pixelFormat: OSType) throws -> CVPixelBuffer {
        var pixelBuffer: CVPixelBuffer?
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        let status = CVPixelBufferCreate(kCFAllocatorDefault, width, height, pixelFormat, attributes as CFDictionary, &pixelBuffer)
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
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
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
        guard let context = CGContext(
            data: baseAddress, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { throw InferenceError.tileProcessingFailed("创建 CGContext 失败") }
        guard let image = context.makeImage() else {
            throw InferenceError.tileProcessingFailed("创建 CGImage 失败")
        }
        return image
    }

    // MARK: - 羽化融合（修复：不进行强制拉伸，坐标严格映射）
    private func blendTile(
        context: CGContext, tile: CGImage,
        tileRect: TileRect, scaleFactor: Int, overlap: Int
    ) {
        let destX = CGFloat(tileRect.x * scaleFactor)
        let destY = CGFloat(tileRect.y * scaleFactor)
        let destW = CGFloat(tile.width)
        let destH = CGFloat(tile.height)
        let destRect = CGRect(x: destX, y: destY, width: destW, height: destH)

        // 边缘块或无重叠直接绘制
        if tileRect.x == 0 && tileRect.y == 0 {
            context.draw(tile, in: destRect)
            return
        }

        let maskWidth = tile.width
        let maskHeight = tile.height
        var maskData = [UInt8](repeating: 255, count: maskWidth * maskHeight)
        
        // 动态计算羽化宽度（取 overlap 的缩放值，最大不超过切片宽/高的 1/4）
        let featherW = min(overlap * scaleFactor, maskWidth / 4)
        let featherH = min(overlap * scaleFactor, maskHeight / 4)

        // 左侧羽化
        if tileRect.x > 0 && featherW > 0 {
            for x in 0..<featherW {
                let alpha = UInt8(255.0 * Float(x) / Float(featherW))
                for y in 0..<maskHeight {
                    maskData[y * maskWidth + x] = alpha
                }
            }
        }

        // 顶部羽化
        if tileRect.y > 0 && featherH > 0 {
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

        context.saveGState()
        context.clip(to: destRect, mask: maskImage)
        context.draw(tile, in: destRect)
        context.restoreGState()
    }

    // MARK: - 辅助
    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        let perTile = elapsed / Double(completed)
        return perTile * Double(total - completed)
    }
}
