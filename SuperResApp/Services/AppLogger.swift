// SuperResApp/Services/AppLogger.swift

import SwiftUI
import Combine
import UIKit
import OSLog

/// 全局日志管理器，用于在 App 内部显示日志 ⭐
@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    //️ 优化 1：定义统一的日志级别
    enum LogLevel: String {
        case debug = "💬 [DBG]"
        case info = "ℹ️ [INF]"
        case warning = "⚠️ [WRN]"
        case error = "❌ [ERR]"
    }
    
    struct LogItem: Identifiable {
        let id = UUID()
        let time: String // ⭐️ 优化 5：直接存格式化后的时间字符串
        let message: String
        let level: LogLevel
    }
    
    @Published var logs: [LogItem] = []
    private let maxLogs = 300 
    
    // ⭐️ 优化 1：引入缓冲池和节流机制
    private var pendingLogs: [LogItem] = []
    private var updateTask: Task<Void, Never>?
    
    // ⭐️ 优化 2：使用 OSLog 替代 print
    private let osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperRes", category: "AppLogger")
    
    // 时间格式化器
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    private init() {
        // 启动定时刷新任务（每 0.1 秒把缓冲池的数据刷到 UI 上）
        startThrottling()
    }
    
    private func startThrottling() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                // 每 100 毫秒刷新一次 UI
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                guard let self = self else { return }
                
                // 取出缓冲池的数据
                if !self.pendingLogs.isEmpty {
                    let newLogs = self.pendingLogs
                    self.pendingLogs.removeAll()
                    
                    self.logs.append(contentsOf: newLogs)
                    if self.logs.count > self.maxLogs {
                        self.logs.removeFirst(self.logs.count - self.maxLogs)
                    }
                }
            }
        }
    }
    
    // ⭐️ 优化 3：使用 nonisolated 允许任意线程调用，并在内部处理线程安全
    nonisolated func log(_ message: String, level: LogLevel = .info) {
        let timeStr = Date().timeIntervalSince1970.description // 暂时用时间戳，稍后在主线程转格式
        
        // 先输出到系统控制台（OSLog 极低开销，不阻塞线程）
        switch level {
        case .debug: osLogger.debug("\(message)")
        case .info:  osLogger.info("\(message)")
        case .warning: osLogger.warning("\(message)")
        case .error: osLogger.error("\(message)")
        }
        
        // 异步丢回主线程缓冲池
        Task { @MainActor in
            let item = LogItem(
                time: self.formatTime(Date()),
                message: message,
                level: level
            )
            self.pendingLogs.append(item)
        }
    }
    
    private func formatTime(_ date: Date) -> String {
        return timeFormatter.string(from: date)
    }
    
    func clear() {
        logs.removeAll()
        pendingLogs.removeAll()
    }
    
    func copyToClipboard() {
        let text = logs.map { "\($0.time) \($0.level.rawValue) \($0.message)" }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }
    
    deinit {
        updateTask?.cancel()
    }
}