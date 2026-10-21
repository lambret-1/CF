// SuperResApp/Services/ModelStore.swift
// 模型存储：actor 缓存已加载 MLModel，支持加载/驱逐/内存警告自动驱逐

import Foundation
import CoreML

/// 模型存储 actor，缓存已加载的 MLModel 实例
actor ModelStore {
    /// 单例
    static let shared = ModelStore()

    /// 已加载的模型缓存：id -> MLModel
    private var loadedModels: [String: MLModel] = [:]

    /// 当前正在使用的模型 id
    private(set) var currentModelID: String?

    /// 最大缓存模型数
    private let maxCachedModels = 2

    private let manifestLoader = ModelManifestLoader.shared
    private let memoryPressure = MemoryPressureMonitor.shared

    private init() {
        // 注册内存警告回调
        Task {
            await memoryPressure.setOnMemoryWarning { [weak self] in
                Task { [weak self] in
                    await self?.evictNonCurrentModels()
                }
            }
        }
    }

    // MARK: - 加载模型

    /// 加载模型（带缓存）
    /// - Parameters:
    ///   - modelID: 模型 id
    ///   - computeUnits: 计算单元
    /// - Returns: 已加载的 MLModel
    func load(modelID: String, computeUnits: MLComputeUnits) async throws -> MLModel {
        // 命中缓存
        if let model = loadedModels[modelID] {
            currentModelID = modelID
            return model
        }

        // 获取模型路径
        guard let modelURL = await resolveModelURL(modelID: modelID) else {
            throw ModelStoreError.modelNotFound(modelID)
        }

        // 内存检查
        if let manifest = await manifestLoader.manifestItem(for: modelID) {
            if !MemoryPressureMonitor.hasSufficientMemory(forModelSize: manifest.size) {
                throw ModelStoreError.insufficientMemory
            }
        }

        // 加载模型
        let config = MLModelConfiguration()
        config.computeUnits = computeUnits

        let model: MLModel
        do {
            model = try MLModel(contentsOf: modelURL, configuration: config)
        } catch {
            // 加载失败，尝试回退到内置 PiperSR
            if modelID != "piper-sr-2x" {
                NSLog("模型 \(modelID) 加载失败，尝试回退到内置 PiperSR：\(error.localizedDescription)")
                return try await fallbackToPiperSR()
            }
            throw ModelStoreError.loadFailed(error.localizedDescription)
        }

        // 缓存管理
        loadedModels[modelID] = model
        currentModelID = modelID
        evictIfNeeded()

        return model
    }

    /// 加载 SinSR 三件套
    func loadSinSR() async throws -> (encoder: MLModel, decoder: MLModel, denoiser: MLModel) {
        let modelsDir = await manifestLoader.compiledModelURL(for: "sinsr").deletingLastPathComponent()

        let encoderURL = modelsDir.appendingPathComponent("sinsr_encoder.mlmodelc")
        let decoderURL = modelsDir.appendingPathComponent("sinsr_decoder.mlmodelc")
        let denoiserURL = modelsDir.appendingPathComponent("sinsr_denoiser.mlmodelc")

        let allConfig = MLModelConfiguration()
        allConfig.computeUnits = .all

        let cpuConfig = MLModelConfiguration()
        cpuConfig.computeUnits = .cpuOnly

        do {
            let encoder = try MLModel(contentsOf: encoderURL, configuration: allConfig)
            let decoder = try MLModel(contentsOf: decoderURL, configuration: allConfig)
            // Denoiser 必须 .cpuOnly
            let denoiser = try MLModel(contentsOf: denoiserURL, configuration: cpuConfig)

            loadedModels["sinsr_encoder"] = encoder
            loadedModels["sinsr_decoder"] = decoder
            loadedModels["sinsr_denoiser"] = denoiser
            currentModelID = "sinsr"

            return (encoder, decoder, denoiser)
        } catch {
            throw ModelStoreError.loadFailed("SinSR 加载失败：\(error.localizedDescription)")
        }
    }

    /// 回退到内置 PiperSR
    private func fallbackToPiperSR() async throws -> MLModel {
        guard let piperURL = await manifestLoader.builtinModelURL(for: "piper-sr-2x") else {
            throw ModelStoreError.fallbackModelNotFound
        }

        let config = MLModelConfiguration()
        config.computeUnits = .cpuAndNeuralEngine
        let model = try MLModel(contentsOf: piperURL, configuration: config)
        loadedModels["piper-sr-2x"] = model
        currentModelID = "piper-sr-2x"
        return model
    }

    // MARK: - 驱逐模型

    /// 驱逐指定模型
    func evict(modelID: String) {
        loadedModels.removeValue(forKey: modelID)
        if currentModelID == modelID {
            currentModelID = nil
        }
        // SinSR 同时驱逐子模型
        if modelID == "sinsr" {
            loadedModels.removeValue(forKey: "sinsr_encoder")
            loadedModels.removeValue(forKey: "sinsr_decoder")
            loadedModels.removeValue(forKey: "sinsr_denoiser")
        }
    }

    /// 驱逐非当前模型（内存警告时调用）
    func evictNonCurrentModels() {
        let current = currentModelID
        for key in loadedModels.keys where key != current &&
            key != "sinsr_encoder" && key != "sinsr_decoder" && key != "sinsr_denoiser" {
            loadedModels.removeValue(forKey: key)
        }
        // 如果当前是 SinSR，保留三个子模型
        if current != "sinsr" {
            loadedModels.removeValue(forKey: "sinsr_encoder")
            loadedModels.removeValue(forKey: "sinsr_decoder")
            loadedModels.removeValue(forKey: "sinsr_denoiser")
        }
    }

    /// 驱逐所有模型
    func evictAll() {
        loadedModels.removeAll()
        currentModelID = nil
    }

    /// 缓存超限时驱逐最旧的模型
    private func evictIfNeeded() {
        guard loadedModels.count > maxCachedModels else { return }
        // 保留当前模型，驱逐其他
        let keysToRemove = loadedModels.keys.filter { $0 != currentModelID }
        for key in keysToRemove.dropFirst(maxCachedModels - 1) {
            loadedModels.removeValue(forKey: key)
        }
    }

    // MARK: - 查询

    /// 模型是否已加载
    func isLoaded(modelID: String) -> Bool {
        loadedModels[modelID] != nil
    }

    /// 获取已加载的模型（不触发加载）
    func loadedModel(modelID: String) -> MLModel? {
        loadedModels[modelID]
    }

    // MARK: - 私有方法

    /// 解析模型文件路径
    private func resolveModelURL(modelID: String) async -> URL? {
        // 1. 先检查内置模型
        if let builtinURL = await manifestLoader.builtinModelURL(for: modelID) {
            return builtinURL
        }

        // 2. 检查已下载编译的模型
        let compiledURL = await manifestLoader.compiledModelURL(for: modelID)
        if FileManager.default.fileExists(atPath: compiledURL.path) {
            return compiledURL
        }

        return nil
    }
}

// MARK: - 内存警告回调设置

extension MemoryPressureMonitor {
    func setOnMemoryWarning(_ handler: @escaping () -> Void) {
        self.onMemoryWarning = handler
    }
}

// MARK: - 模型存储错误

enum ModelStoreError: LocalizedError {
    case modelNotFound(String)
    case insufficientMemory
    case loadFailed(String)
    case fallbackModelNotFound

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let id):
            return "模型文件不存在：\(id)"
        case .insufficientMemory:
            return "内存不足，无法加载模型"
        case .loadFailed(let detail):
            return "模型加载失败：\(detail)"
        case .fallbackModelNotFound:
            return "回退模型 PiperSR 未找到"
        }
    }
}
