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

    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        // ... (前面的加载代码不变)
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
        
        // ⭐️ 核心改动：路由逻辑升级
        // 如果模型大且原图不大，走极速拉伸；如果原图非常大（比如 4K），强行拉伸会丢失文字细节，必须走切块。
        let isHugeImage = image.width > 2000 || image.height > 2000
        let isLargeTile = inputInfo.width >= 512
        
        // 哪怕模型是 512，只要图太大，就切块，防止文字糊掉
        let useStretch = isLargeTile && !isHugeImage
        
        let engine: SuperResolutionEngine = useStretch ? DirectStretchEngine() : TilingEngine()

        let finalCGImage = try await engine.upscale(
            image: image,
            modelID: modelID,
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
            outputSize: CGSize(width: targetWidth == 0 ? image.width : targetWidth, height: targetHeight == 0 ? image.height : targetHeight),
            elapsedSeconds: elapsed, modelID: modelID,
            tileSize: inputInfo.width, totalTiles: 1
        )
    }

    // ... fastUpscale 保持不变 ...
    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        let engine = DirectStretchEngine()
        return try await engine.upscale(
            image: image,
            modelID: modelID,
            model: model,
            inputInfo: inputInfo,
            scaleFactor: descriptor.scaleFactor,
            progressHandler: nil
        )
    }
}