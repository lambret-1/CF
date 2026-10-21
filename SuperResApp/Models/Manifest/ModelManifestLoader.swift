// SuperResApp/Models/Manifest/ModelManifestLoader.swift
// 模型清单加载器：从 Bundle 读取 JSON，合并本地状态

import Foundation

/// 模型清单加载器，负责读取 manifest 并维护运行时状态
actor ModelManifestLoader {
    /// 单例
    static let shared = ModelManifestLoader()

    /// 内存中的清单条目
    private(set) var items: [ModelManifestItem] = []

    /// 运行时状态缓存（id -> 状态）
    private var statusCache: [String: ModelStatus] = [:]

    /// 下载进度缓存（id -> 进度）
    private var progressCache: [String: Double] = [:]

    /// 已下载字节缓存
    private var downloadedBytesCache: [String: Int64] = [:]

    /// 失败原因缓存
    private var failureCache: [String: String] = [:]

    /// 已编译模型目录
    private let modelsDirectory: URL

    private init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        modelsDirectory = paths[0].appendingPathComponent("Models", isDirectory: true)
        try? FileManager.default.createDirectory(at: modelsDirectory, withIntermediateDirectories: true)
    }

    // MARK: - 加载清单

    /// 从 Bundle 加载 model_manifest.json
    func loadFromBundle() async throws {
        guard let url = Bundle.main.url(forResource: "model_manifest", withExtension: "json") else {
            throw ManifestError.bundleFileNotFound
        }
        let data = try Data(contentsOf: url)
        items = try JSONDecoder().decode([ModelManifestItem].self, from: data)
        refreshStatuses()
    }

    /// 刷新所有模型的本地状态
    func refreshStatuses() {
        for item in items {
            if item.builtin {
                statusCache[item.id] = .builtin
            } else if isModelCompiled(id: item.id) {
                if statusCache[item.id] != .downloading && statusCache[item.id] != .queued && statusCache[item.id] != .paused {
                    statusCache[item.id] = .downloaded
                }
            } else if statusCache[item.id] == nil {
                statusCache[item.id] = .notDownloaded
            }
        }
    }

    /// 检查模型是否已编译存在
    private func isModelCompiled(id: String) -> Bool {
        let modelURL = modelsDirectory.appendingPathComponent("\(id).mlmodelc")
        return FileManager.default.fileExists(atPath: modelURL.path)
    }

    // MARK: - 查询

    /// 获取所有模型的运行时信息
    func allRuntimeInfo() -> [ModelRuntimeInfo] {
        return items.map { item in
            ModelRuntimeInfo(
                id: item.id,
                manifest: item,
                status: statusCache[item.id] ?? .notDownloaded,
                downloadProgress: progressCache[item.id] ?? 0,
                downloadedBytes: downloadedBytesCache[item.id] ?? 0,
                failureReason: failureCache[item.id]
            )
        }
    }

    /// 获取单个模型的运行时信息
    func runtimeInfo(for id: String) -> ModelRuntimeInfo? {
        guard let item = items.first(where: { $0.id == id }) else { return nil }
        return ModelRuntimeInfo(
            id: id,
            manifest: item,
            status: statusCache[id] ?? .notDownloaded,
            downloadProgress: progressCache[id] ?? 0,
            downloadedBytes: downloadedBytesCache[id] ?? 0,
            failureReason: failureCache[id]
        )
    }

    /// 获取内置模型列表
    func builtinModels() -> [ModelRuntimeInfo] {
        allRuntimeInfo().filter { $0.isBuiltin }
    }

    /// 获取可下载模型列表
    func downloadableModels() -> [ModelRuntimeInfo] {
        allRuntimeInfo().filter { !$0.isBuiltin }
    }

    /// 根据 id 获取清单条目
    func manifestItem(for id: String) -> ModelManifestItem? {
        items.first { $0.id == id }
    }

    // MARK: - 状态更新

    /// 更新模型状态
    func updateStatus(_ status: ModelStatus, for id: String) {
        statusCache[id] = status
        if status != .failed {
            failureCache.removeValue(forKey: id)
        }
    }

    /// 更新下载进度
    func updateProgress(_ progress: Double, downloadedBytes: Int64, for id: String) {
        progressCache[id] = progress
        downloadedBytesCache[id] = downloadedBytes
    }

    /// 标记失败
    func markFailed(id: String, reason: String) {
        statusCache[id] = .failed
        failureCache[id] = reason
    }

    /// 清除失败状态
    func clearFailure(id: String) {
        failureCache.removeValue(forKey: id)
        if statusCache[id] == .failed {
            statusCache[id] = isModelCompiled(id: id) ? .downloaded : .notDownloaded
        }
    }

    /// 获取模型编译后的路径
    func compiledModelURL(for id: String) -> URL {
        modelsDirectory.appendingPathComponent("\(id).mlmodelc")
    }

    /// 获取内置模型在 Bundle 中的路径
    func builtinModelURL(for id: String) -> URL? {
        // 内置模型文件名映射（区分大小写）
        let nameMap: [String: String] = [
            "piper-sr-2x": "PiperSR_2x",
            "realesrgan-x4v3": "RealESRGAN_x4v3"
        ]
        let name = nameMap[id] ?? id.replacingOccurrences(of: "-", with: "_")
        return Bundle.main.url(forResource: name, withExtension: "mlmodelc")
    }

    // MARK: - 存储用量

    /// 计算已下载模型占用的存储空间
    func storageUsed() -> Int64 {
        var total: Int64 = 0
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(at: modelsDirectory, includingPropertiesForKeys: [.fileSizeKey]) else {
            return 0
        }
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += Int64(size)
            }
        }
        return total
    }

    /// 获取设备可用存储空间
    func storageFree() -> Int64 {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        if let values = try? documentDirectory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]) {
            return Int64(values.volumeAvailableCapacityForImportantUsage ?? 0)
        }
        return 0
    }

    /// 清理临时文件
    func cleanupTemporaryFiles() {
        let tempDir = FileManager.default.temporaryDirectory
        let tmpModels = tempDir.appendingPathComponent("SuperResModels")
        try? FileManager.default.removeItem(at: tmpModels)
    }
}

// MARK: - 错误类型

enum ManifestError: LocalizedError {
    case bundleFileNotFound
    case decodeFailed(String)
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .bundleFileNotFound:
            return "模型清单文件未找到"
        case .decodeFailed(let detail):
            return "模型清单解析失败：\(detail)"
        case .modelNotFound(let id):
            return "模型不存在：\(id)"
        }
    }
}
