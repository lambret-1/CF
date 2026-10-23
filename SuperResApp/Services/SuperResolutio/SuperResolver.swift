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

    // MARK: - 照片超分（切块推理）
    func upscale(
        image: CGImage,
        modelID: String,
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

        let inputInfo = try ModelInputInfo.parse(from: model)
        
        await AppLogger.shared.log("📷 [Photo] 模型尺寸: \(inputInfo.width)x\(inputInfo.height), 类型: \(inputInfo.isImageInput ? "Image" : "Array")")

        let overlap = 16
        let tiles = ImageTileProcessor.calculateTiles(
            width: image.width,
            height: image.height,
            tileSize: inputInfo.width,
            overlap: overlap
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
                currentTile: index + 1,
                totalTiles: totalTiles,
                fraction: Double(index) / Double(totalTiles),
                elapsedSeconds: elapsed,
                estimatedRemainingSeconds: estimateRemaining(elapsed: elapsed, completed: index, total: totalTiles)
            ))

            guard let inputTile = ImageTileProcessor.cropTile(from: image, tile: tile, targetSize: inputInfo.width) else {
                continue
            }
            
            do {
                let outputTile = try ImageTileProcessor.processTile(image: inputTile, model: model, isNCHW: inputInfo.isNCHW)
                blendTile(
                    context: outputContext,
                    tileImage: outputTile,
                    tileInfo: tile,
                    scaleFactor: descriptor.scaleFactor
                )
            } catch {
                await AppLogger.shared.log("块 \(index) 推理失败: \(error)", isError: true)
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
            tileSize: inputInfo.width, totalTiles: totalTiles
        )
    }

    // MARK: - 实时预览（快速整图推理）
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let model = try await modelStore.load(
            modelID: modelID,
            computeUnits: descriptor.primaryComputeUnits
        )

        let inputInfo = try ModelInputInfo.parse(from: model)
        
        guard let inputTile = ImageTileProcessor.cropTile(
            from: image,
            tile: ImageTileProcessor.TileInfo(x: 0, y: 0, width: image.width, height: image.height),
            targetSize: inputInfo.width
        ) else {
            throw InferenceError.tileProcessingFailed("创建输入图失败")
        }

        return try ImageTileProcessor.processTile(image: inputTile, model: model, isNCHW: inputInfo.isNCHW)
    }

    // MARK: - 拼接辅助
    private func blendTile(context: CGContext, tileImage: CGImage, tileInfo: ImageTileProcessor.TileInfo, scaleFactor: Int) {
        let drawWidth = CGFloat(tileInfo.width * scaleFactor)
        let drawHeight = CGFloat(tileInfo.height * scaleFactor)
        let destX = CGFloat(tileInfo.x * scaleFactor)
        let destY = CGFloat(tileInfo.y * scaleFactor)
        
        // 安全裁切，防止越界
        let safeWidth = min(Int(drawWidth), tileImage.width)
        let safeHeight = min(Int(drawHeight), tileImage.height)
        let cropRect = CGRect(x: 0, y: 0, width: safeWidth, height: safeHeight)
        
        guard let validTile = tileImage.cropping(to: cropRect) else { return }
        
        context.saveGState()
        context.translateBy(x: destX, y: destY + drawHeight)
        context.scaleBy(x: 1.0, y: -1.0)
        context.draw(validTile, in: CGRect(x: 0, y: 0, width: drawWidth, height: drawHeight))
        context.restoreGState()
    }

    private func estimateRemaining(elapsed: TimeInterval, completed: Int, total: Int) -> TimeInterval? {
        guard completed > 0 else { return nil }
        return (elapsed / Double(completed)) * Double(total - completed)
    }
}