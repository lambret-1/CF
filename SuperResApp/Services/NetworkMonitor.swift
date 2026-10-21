// SuperResApp/Services/NetworkMonitor.swift
// 网络状态监控：NWPathMonitor，判断是否蜂窝/是否计费

import Foundation
import Network

/// 网络监控 actor，使用 NWPathMonitor 监听网络状态
actor NetworkMonitor {
    /// 单例
    static let shared = NetworkMonitor()

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.superres.networkmonitor")
    private(set) var currentPath: NWPath?
    private var updateContinuation: AsyncStream<NWPath>.Continuation?

    private init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { [weak self] in
                await self?.handlePathUpdate(path)
            }
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    private func handlePathUpdate(_ path: NWPath) {
        currentPath = path
        updateContinuation?.yield(path)
    }

    /// 网络状态变化的异步流
    var pathUpdates: AsyncStream<NWPath> {
        AsyncStream { continuation in
            updateContinuation = continuation
            continuation.onTermination = { [weak self] _ in
                Task { [weak self] in
                    await self?.clearContinuation()
                }
            }
        }
    }

    private func clearContinuation() {
        updateContinuation = nil
    }

    /// 是否有网络连接
    var isConnected: Bool {
        currentPath?.status == .satisfied
    }

    /// 是否为蜂窝网络（昂贵连接）
    var isExpensive: Bool {
        currentPath?.isExpensive ?? false
    }

    /// 是否为受限网络（Low Data Mode）
    var isConstrained: Bool {
        currentPath?.isConstrained ?? false
    }

    /// 是否为 Wi-Fi
    var isWiFi: Bool {
        guard let path = currentPath else { return false }
        return path.status == .satisfied &&
               !path.isExpensive &&
               path.usesInterfaceType(.wifi)
    }

    /// 是否为蜂窝
    var isCellular: Bool {
        currentPath?.usesInterfaceType(.cellular) ?? false
    }

    /// 检查是否允许下载指定模型
    /// - Parameter wifiOnly: 模型是否仅 Wi-Fi 下载
    /// - Returns: 是否允许
    func canDownload(wifiOnly: Bool) -> Bool {
        guard isConnected else { return false }
        if wifiOnly {
            return isWiFi
        }
        return true
    }

    /// 等待网络连接可用（超时后返回当前状态）
    func waitForConnection(timeout: TimeInterval = 10) async -> Bool {
        if isConnected { return true }
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try? await Task.sleep(nanoseconds: 500_000_000)
            if isConnected { return true }
        }
        return false
    }
}
