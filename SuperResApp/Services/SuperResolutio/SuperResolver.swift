// SuperResApp/Services/SuperResolutio/SuperResolver.swift

import Foundation
import CoreML
import CoreImage
import UIKit

actor SuperResolver {
    static let shared = SuperResolver()
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    
    // ⭐️ 改用 Task 引用，方便实现真正的取消
    private var currentTask: Task<InferenceResult, Error>?
    
    private init() {}

    func cancel() {
        // 取消当前正在执行的 Task
        currentTask?.cancel()
        currentTask = nil
    }

    func upscale(
        image: CGImage,
        modelID: String,
        progressHandler: ((InferenceProgress) -> Void)? = nil
    ) async throws -> InferenceResult {
        
        // 1. 如果之前有任务，先取消
        cancel()
        
        // 2. 包装成一个可取消的 Task
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
            
            // 检查是否被取消（加载模型期间可能被取消）
            try Task.checkCancellation()
            
            // ⭐️ 修复 1：重新定义引擎选择逻辑
            // 原则：如果原图很小，直接拉伸；如果原图很大，必须分块，防止 OOM
            let engine: SuperResolutionEngine
            
            if modelID == "piper-sr-2x" {
                engine = PiperSREngine()
            } else if image.width <= inputInfo.width && image.height <= inputInfo.height {
                // 只有当原图小于等于模型输入尺寸时，才用 DirectStretch 暴力拉伸
                engine = DirectStretchEngine()
            } else {
                // 大图用 Tiling 分块
                engine = TilingEngine()
            }
            
            let finalCGImage = try await engine.upscale(
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
            
            // ⭐️ 修复 3：粗略估算切块数量（更精确的做法是让 engine 返回统计结果）
            let tileWidth = inputInfo.width
            // 简单估算：瓦片面积 / 有效面积（假设 1/16 重叠）
            let effectiveTileSize = Double(tileWidth) * 0.85 
            let estimatedTiles = max(1, Int((Double(image.width) / effectiveTileSize) * (Double(image.height) / effectiveTileSize)))
            
            return InferenceResult(
                outputImage: finalCGImage,
                inputSize: CGSize(width: image.width, height: image.height),
                outputSize: CGSize(width: targetWidth, height: targetHeight),
                elapsedSeconds: elapsed, modelID: modelID,
                tileSize: tileWidth, 
                totalTiles: engine is DirectStretchEngine ? 1 : estimatedTiles // 动态统计
            )
        }
        
        self.currentTask = task
        defer { self.currentTask = nil }
        
        return try await task.value
    }

    func fastUpscale(image: CGImage, modelID: String) async throws -> CGImage {
        // 直接复用上方逻辑，或者精简版本
        guard let manifest = await manifestLoader.manifestItem(for: modelID) else {
            throw InferenceError.modelNotLoaded(modelID)
        }
        let descriptor = ModelDescriptor.descriptor(for: manifest)

        let config = MLModelConfiguration()
        config.computeUnits = .all

        let model = try await modelStore.load(modelID: modelID, computeUnits: config.computeUnits)
        let inputInfo = try ModelInputInfo.parse(from: model)
        
        // fastUpscale 通常用于 UI 预览，用 DirectStretch 是最快的
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