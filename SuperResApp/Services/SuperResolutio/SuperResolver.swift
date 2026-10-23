import Foundation
import CoreML
import CoreImage
import UIKit

actor SuperResolver {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    
    private var currentTask: Task<InferenceResult, Error>?
    
    private init() {}

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
    }

    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        
        cancel() // 如果之前有任务，先取消
        
        let task = Task<InferenceResult, Error> {
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
            
            // ⭐️ 接收 EngineResult
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
            
            // ⭐️ 使用真实的统计信息返回
            return InferenceResult(
                outputImage: engineResult.image, // 提取图片
                inputSize: CGSize(width: image.width, height: image.height),
                outputSize: CGSize(width: targetWidth, height: targetHeight),
                elapsedSeconds: elapsed, 
                modelID: modelID,
                tileSize: engineResult.tileSize, // 取真实瓦片尺寸
                totalTiles: engineResult.totalTiles // 取真实切片数量
            )
        }
        
        self.currentTask = task
        defer { self.currentTask = nil }
        
        return try await task.value
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
        let result = try await engine.upscale(
            image: image,
            modelID: modelID,
            model: model,
            inputInfo: inputInfo,
            scaleFactor: descriptor.scaleFactor,
            progressHandler: nil
        )
        return result.image // ⭐️ 返回图片本身
    }
}