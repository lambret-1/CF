// SuperResApp/Services/SuperResolutio/SuperResolver.swift

import Foundation
import CoreML
import CoreImage
import UIKit
import CoreVideo

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
        
        // ⭐️ 硬核测速开始 (测试单块 256 推理耗时)
        if let inputName = model.modelDescription.inputDescriptionsByName.first?.key {
            let testW = min(256, inputInfo.width)
            let testH = min(256, inputInfo.height)
            if let testBuffer = makeBGRAPixelBuffer(from: image, width: testW, height: testH) {
                let provider = try MLDictionaryFeatureProvider(dictionary: [inputName: MLFeatureValue(pixelBuffer: testBuffer)])
                let start = Date()
                _ = try? await model.prediction(from: provider)
                let cost = Date().timeIntervalSince(start) * 1000
                await AppLogger.shared.log("⏱️ 单块 \(testW)x\(testH) 推理耗时: \(String(format: "%.1f", cost)) 毫秒")
            }
        }
        // ⭐️ 硬核测速结束

        await AppLogger.shared.log("🚀 路由启动: \(modelID)")

        // 核心路由逻辑：如果模型支持的瓦片 >= 512（如 x4），直接拉伸；如果较小（如 256），必须切块
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

    // MARK: - 私有工具 (用于测速)
    private func makeBGRAPixelBuffer(from image: CGImage, width: Int, height: Int) -> CVPixelBuffer? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true
        ]
        var pb: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, width, height, kCVPixelFormatType_32BGRA, attrs as CFDictionary, &pb)
        guard let buffer = pb else { return nil }
        
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        
        guard let ctx = CGContext(
            data: CVPixelBufferGetBaseAddress(buffer),
            width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return nil }
        
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return buffer
    }
}