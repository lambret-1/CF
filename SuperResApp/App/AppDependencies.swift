// SuperResApp/App/AppDependencies.swift
// 应用依赖容器：统一初始化和持有各 Service

import Foundation

/// 应用依赖容器，持有所有全局 Service
@MainActor
final class AppDependencies: ObservableObject {
    /// 单例
    static let shared = AppDependencies()

    // MARK: - Services

    let manifestLoader = ModelManifestLoader.shared
    let downloader = ModelDownloader.shared
    let compiler = ModelCompiler.shared
    let modelStore = ModelStore.shared
    let superResolver = SuperResolver.shared
    let photoLibrary = PhotoLibraryService.shared
    let cameraSession = CameraSession.shared
    let networkMonitor = NetworkMonitor.shared
    let memoryPressure = MemoryPressureMonitor.shared

    // MARK: - 状态

    @Published private(set) var isReady = false
    @Published private(set) var startupError: String?
    @Published var showFirstLaunchGuide = false

    private init() {}

    // MARK: - 初始化

    /// 应用启动时调用
    func initialize() async {
        do {
            // 加载模型清单
            try await manifestLoader.loadFromBundle()

            // 检查首次启动
            let hasLaunched = UserDefaults.standard.bool(forKey: "hasLaunchedBefore")
            if !hasLaunched {
                showFirstLaunchGuide = true
                UserDefaults.standard.set(true, forKey: "hasLaunchedBefore")
            }

            isReady = true
        } catch {
            startupError = error.localizedDescription
            isReady = true // 即使失败也允许进入，显示错误
        }
    }
}
