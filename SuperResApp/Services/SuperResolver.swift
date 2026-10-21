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

        guard let inputDesc = model.modelDescription.inputDescriptionsByName.first?.value,
              let constraint = inputDesc.multiArrayConstraint else {
            // 修复点：改为抛出现有的错误枚举
            throw InferenceError.tileProcessingFailed("模型无输入或输入约束不匹配")
        }
        
        let shape = constraint.shape.map { $0.intValue }
        var height = 0
        var width = 0
        
        if shape.count == 4 {
            if shape[1] == 3 { // NCHW
                height = shape[2]
                width = shape[3]
            } else if shape[3] == 3 { // NHWC
                height = shape[1]
                width = shape[2]
            } else {
                throw InferenceError.tileProcessingFailed("未知的模型输入形状")
            }
        } else {
            throw InferenceError.tileProcessingFailed("模型输入维度不是 4")
        }

        let overlap = 16
        let tiles = calculateTiles(width: image.width, height: image.height, tileSize: width, overlap: overlap)
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
                currentTile: index + 1,
                totalTiles: totalTiles,
                fraction: Double(index) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(elapsed: elapsed, completed: index, total: totalTiles)
            ))

            guard let inputTile = createTile(from: image, tile: tile, targetSize: width) else {
                continue
            }
            
            guard let outputTile = try? processTile(image: inputTile, model: model, isNCHW: shape[1] == 3) else {
                continue
            }

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
            tileSize: width, totalTiles: totalTiles
        )
    }

    // MARK: - 网格计算
    struct TileInfo {
        let x: Int
        let y: Int
        let width: Int
        let height: Int
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

    private func createTile(from image: CGImage, tile: TileInfo, targetSize: Int) -> CGImage? {
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

    private func processTile(image: CGImage, model: MLModel, isNCHW: Bool) throws -> CGImage {
        try autoreleasepool {
            guard let inputDict = model.modelDescription.inputDescriptionsByName.first else {
                throw InferenceError.tileProcessingFailed("模型无输入")
            }
            let inputName = inputDict.key
            let inputFeatureDesc = inputDict.value

            let featureProvider: MLDictionaryFeatureProvider
            if inputFeatureDesc.type == .multiArray {
                let constraint = inputFeatureDesc.multiArrayConstraint!
                let array = try imageToMultiArray(image, constraint: constraint, isNCHW: isNCHW)
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
                return try multiArrayToImage(outputArray, isNCHW: isNCHW)
            } else if outputFeature.type == .image, let outputBuffer = outputFeature.imageBufferValue {
                return try createCGImage(from: outputBuffer)
            }
            throw InferenceError.tileProcessingFailed("输出格式不支持")
        }
    }

    // MARK: - 拼接
    private func blendTile(context: CGContext, tileImage: CGImage, tileInfo: TileInfo, scaleFactor: Int) {
        let drawWidth = CGFloat(tileInfo.width * scaleFactor)
        let drawHeight = CGFloat(tileInfo.height * scaleFactor)
        let destX = CGFloat(tileInfo.x * scaleFactor)
        let destY = CGFloat(tileInfo.y * scaleFactor)
        
        let cropRect = CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight)
        guard let validTile = tileImage.cropping(to: cropRect) else { return }
        
        context.saveGState()
        context.translateBy(x: destX, y: destY + drawHeight)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(validTile, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
        context.restoreGState()
    }

    // MARK: - 彻底安全的 MLMultiArray 转换（防闪退核心）
    private func imageToMultiArray(_ image: CGImage, constraint: MLMultiArrayConstraint, isNCHW: Bool) throws -> MLMultiArray {
        let shape = constraint.shape.map { $0.intValue }
        let height = isNCHW ? shape[2] : shape[1]
        let width = isNCHW ? shape[3] : shape[2]
        
        let array = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: constraint.dataType)
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建 CGContext 失败")
        }
        
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                let r = Float(pixelData[pixelIndex]) / 255.0
                let g = Float(pixelData[pixelIndex + 1]) / 255.0
                let b = Float(pixelData[pixelIndex + 2]) / 255.0
                
                if isNCHW {
                    array[[0, 0, y, x] as [NSNumber]] = NSNumber(value: r)
                    array[[0, 1, y, x] as [NSNumber]] = NSNumber(value: g)
                    array[[0, 2, y, x] as [NSNumber]] = NSNumber(value: b)
                } else {
                    array[[0, y, x, 0] as [NSNumber]] = NSNumber(value: r)
                    array[[0, y, x, 1] as [NSNumber]] = NSNumber(value: g)
                    array[[0, y, x, 2] as [NSNumber]] = NSNumber(value: b)
                }
            }
        }
        return array
    }

    private func multiArrayToImage(_ array: MLMultiArray, isNCHW: Bool) throws -> CGImage {
        let shape = array.shape.map { $0.intValue }
        let height = isNCHW ? shape[2] : shape[1]
        let width = isNCHW ? shape[3] : shape[2]
        
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * width
        var pixelData = [UInt8](repeating: 0, count: height * bytesPerRow)

        for y in 0..<height {
            for x in 0..<width {
                let pixelIndex = y * bytesPerRow + x * bytesPerPixel
                
                let r: Float
                let g: Float
                let b: Float
                
                if isNCHW {
                    r = array[[0, 0, y, x] as [NSNumber]].floatValue
                    g = array[[0, 1, y, x] as [NSNumber]].floatValue
                    b = array[[0, 2, y, x] as [NSNumber]].floatValue
                } else {
                    r = array[[0, y, x, 0] as [NSNumber]].floatValue
                    g = array[[0, y, x, 1] as [NSNumber]].floatValue
                    b = array[[0, y, x, 2] as [NSNumber]].floatValue
                }
                
                pixelData[pixelIndex] = UInt8(clamping: Int((r * 255.0).rounded()))
                pixelData[pixelIndex + 1] = UInt8(clamping: Int((g * 255.0).rounded()))
                pixelData[pixelIndex + 2] = UInt8(clamping: Int((b * 255.0).rounded()))
                pixelData[pixelIndex + 3] = 255
            }
        }
        
        guard let context = CGContext(data: &pixelData, width: width, height: height, bitsPerComponent: 8, bytesPerRow: bytesPerRow, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw InferenceError.tileProcessingFailed("创建输出 CGContext 失败")
        }
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
