import Foundation
import CoreML
import CoreImage
import UIKit

// ⭐️ 1. 从 actor 改为 final class，并标记为 @unchecked Sendable
final class SuperResolver: @unchecked Sendable {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    
    private init() {}

    // ⭐️ 2. 如果外部是视频流并发的，不需要在超分引擎里存全局的 cancel 状态。
    // 取消逻辑由外层的 VideoSuperResProcessor 已经处理了。
    func cancel() {
        // 留空或移除。避免并发任务互相取消。
    }

    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        
        let startTime = Date()
        
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)
        
        let config = MLModelConfiguration()
        config.computeUnits = .all
        
        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        try Task.checkCancellation()
        
        let engine: SuperResolutionEngine
        if modelID == "piper-sr-2x" {
            engine = PiperSREngine()
        } else if image.width <= inputInfo.width && image.height <= inputInfo.height {
            engine = DirectStretchEngine()
        } else {
            engine = TilingEngine()
        }
        
        let engineResult = try await engine.upscale(
            image: image,
            modelID: modelID,
            model: model,
            inputInfo: inputInfo,
            scaleFactor: descriptor.scaleFactor,
            progressHandler: progressHandler
        )
        
        try Task.checkCancellation()
        
        let targetWidth = image.width * descriptor.scaleFactor
        let targetHeight = image.height * descriptor.scaleFactor
        let elapsed = Date().timeIntervalSince(startTime)
        
        return InferenceResult(
            outputImage: engineResult.image,
            inputSize: CGSize(width: image.width, height: image.height),
            outputSize: CGSize(width: targetWidth, height: targetHeight),
            elapsedSeconds: elapsed, 
            modelID: modelID,
            tileSize: engineResult.tileSize,
            totalTiles: engineResult.totalTiles
        )
    }

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
        
        // ⭐️ 这里实际执行推理
        let result = try await engine.upscale(
            image: image,
            modelID: modelID,
            model: model,
            inputInfo: inputInfo,
            scaleFactor: descriptor.scaleFactor,
            progressHandler: nil
        )
        return result.image
    }
}