// SuperResApp/Services/SuperResolutio/SuperResolver.swift

import Foundation
import CoreML
import CoreImage
import UIKit

actor SuperResolver {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    private var isCancelled = false
    private let ciContext = CIContext(options: [.workingColorSpace: NSNull()])

    private init() {}

    func cancel() { isCancelled = true }

    // MARK: - 路由分发中心
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

        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        await AppLogger.shared.log("🚀 路由启动: \(modelID)")

        // ⭐️ 核心修改：根据模型的输入瓦片尺寸来决定策略
        // 如果模型支持的瓦片 >= 512（如 x4, x4plus），直接拉伸，极速且清晰
        // 如果瓦片较小（如 256），必须切块，否则会糊成马赛克
        let isLargeTile = inputInfo.width >= 512
        let engine: SuperResolutionEngine = isLargeTile ? DirectStretchEngine() : TilingEngine()
        
        if isLargeTile {
            await AppLogger.shared.log("⚡️ [DirectStretch] 极速整图模式 (瓦片: \(inputInfo.width))")
        } else {
            await AppLogger.shared.log("⚡️ [Tiling] 高清切块模式 (瓦片: \(inputInfo.width))")
        }

        let finalCGImage = try await engine.upscale(
            image: image,
            model: model,
            inputInfo: inputInfo,
            scaleFactor: descriptor.scaleFactor,
            progressHandler: progressHandler
        )

        let targetWidth = image.width * descriptor.scaleFactor
        let targetHeight = image.height * descriptor.scaleFactor
        let elapsed = Date().timeIntervalSince(startTime)

        return InferenceResult(
            outputImage: finalCGImage,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: targetWidth, height: targetHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: inputInfo.width, totalTiles: 1
        )
    }

    // MARK: - 实时预览（极速版）
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        // 实时预览一律用极速拉伸
        let engine = DirectStretchEngine()
        return try await engine.upscale(image: image, model: model, inputInfo: inputInfo, scaleFactor: descriptor.scaleFactor, progressHandler: nil)
    }
}