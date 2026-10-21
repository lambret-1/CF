// SuperResApp/Features/ModelManager/ModelManagerViewModel.swift
// 模型管理视图模型：下载/暂停/删除/编译状态管理

import Foundation
import SwiftUI

/// 模型管理视图模型
@MainActor
final class ModelManagerViewModel: ObservableObject {
    // MARK: - 发布属性

    @Published private(set) var models: [ModelRuntimeInfo] = []
    @Published private(set) var storageUsed: Int64 = 0
    @Published private(set) var storageFree: Int64 = 0
    @Published private(set) var isLoading = true
    @Published var showDeleteConfirmation: Bool = false
    @Published var modelToDelete: ModelRuntimeInfo?
    @Published var showCellularConfirmation: Bool = false
    @Published var modelToDownload: ModelRuntimeInfo?

    // MARK: - 依赖

    private let manifestLoader = ModelManifestLoader.shared
    private let downloader = ModelDownloader.shared
    private let compiler = ModelCompiler.shared
    private let networkMonitor = NetworkMonitor.shared

    // MARK: - 初始化

    init() {
        setupCallbacks()
    }

    private func setupCallbacks() {
        Task {
            await downloader.setProgressHandler { [weak self] id, downloaded, total, progress in
                Task { @MainActor in
                    self?.updateModel(id: id) { model in
                        model.downloadProgress = progress
                        model.downloadedBytes = downloaded
                    }
                }
            }

            await downloader.setCompletionHandler { [weak self] id, zipURL in
                Task {
                    do {
                        if id == "sinsr" {
                            _ = try await self?.compiler.compileSinSRBundle(zipURL: zipURL)
                        } else {
                            _ = try await self?.compiler.compile(modelID: id, zipURL: zipURL)
                        }
                        await self?.refreshModels()
                        await MainActor.run {
                            ToastManager.shared.show("模型下载完成", type: .success)
                        }
                    } catch {
                        await self?.manifestLoader.markFailed(id: id, reason: error.localizedDescription)
                        await self?.refreshModels()
                    }
                }
            }

            await downloader.setFailureHandler { [weak self] id, error in
                Task { @MainActor in
                    self?.updateModel(id: id) { model in
                        model.status = .failed
                        model.failureReason = error.localizedDescription
                    }
                }
            }
        }
    }

    // MARK: - 数据加载

    func loadModels() async {
        isLoading = true
        do {
            try await manifestLoader.loadFromBundle()
        } catch {
            NSLog("加载模型清单失败：\(error.localizedDescription)")
        }
        await refreshModels()
        isLoading = false
    }

    func refreshModels() async {
        models = await manifestLoader.allRuntimeInfo()
        storageUsed = await manifestLoader.storageUsed()
        storageFree = await manifestLoader.storageFree()
    }

    // MARK: - 下载操作

    func downloadModel(_ model: ModelRuntimeInfo) async {
        // Wi-Fi 检查
        if model.wifiOnly {
            let isExpensive = await networkMonitor.isExpensive
            if isExpensive {
                modelToDownload = model
                showCellularConfirmation = true
                return
            }
        }

        await manifestLoader.clearFailure(id: model.id)
        await downloader.download(modelID: model.id)
        await refreshModels()
    }

    func confirmCellularDownload() async {
        guard let model = modelToDownload else { return }
        showCellularConfirmation = false
        await manifestLoader.clearFailure(id: model.id)
        await downloader.download(modelID: model.id)
        modelToDownload = nil
        await refreshModels()
    }

    func pauseDownload(_ model: ModelRuntimeInfo) async {
        await downloader.pause(modelID: model.id)
        await refreshModels()
    }

    func resumeDownload(_ model: ModelRuntimeInfo) async {
        await downloader.resume(modelID: model.id)
        await refreshModels()
    }

    func cancelDownload(_ model: ModelRuntimeInfo) async {
        await downloader.cancel(modelID: model.id)
        await refreshModels()
    }

    // MARK: - 删除操作

    func requestDelete(_ model: ModelRuntimeInfo) {
        modelToDelete = model
        showDeleteConfirmation = true
    }

    func confirmDelete() async {
        guard let model = modelToDelete else { return }
        showDeleteConfirmation = false

        do {
            try await compiler.delete(modelID: model.id)
            ToastManager.shared.show("模型已删除", type: .success)
        } catch {
            ToastManager.shared.show("删除失败：\(error.localizedDescription)", type: .error)
        }

        modelToDelete = nil
        await refreshModels()
    }

    // MARK: - 清理缓存

    func cleanupCache() async {
        await manifestLoader.cleanupTemporaryFiles()
        ToastManager.shared.show("临时文件已清理", type: .success)
    }

    // MARK: - 分组

    var builtinModels: [ModelRuntimeInfo] {
        models.filter { $0.isBuiltin }
    }

    var downloadableModels: [ModelRuntimeInfo] {
        models.filter { !$0.isBuiltin }
    }

    // MARK: - 私有方法

    private func updateModel(id: String, update: (inout ModelRuntimeInfo) -> Void) {
        guard let index = models.firstIndex(where: { $0.id == id }) else { return }
        update(&models[index])
    }
}

// MARK: - ModelDownloader 扩展（设置回调）

extension ModelDownloader {
    func setProgressHandler(_ handler: @escaping (String, Int64, Int64, Double) -> Void) {
        self.progressHandler = handler
    }

    func setCompletionHandler(_ handler: @escaping (String, URL) -> Void) {
        self.completionHandler = handler
    }

    func setFailureHandler(_ handler: @escaping (String, Error) -> Void) {
        self.failureHandler = handler
    }
}
