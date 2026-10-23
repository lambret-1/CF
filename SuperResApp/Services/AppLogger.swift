// SuperResApp/Services/AppLogger.swift

import SwiftUI
import Combine
import UIKit
import OSLog

/// 全局日志管理器，用于在 App 内部显示日志 ⭐
@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    enum LogLevel: String {
        case debug = "💬 [DBG]"
        case info = "ℹ️ [INF]"
        case warning = "⚠️ [WRN]"
        case error = "❌ [ERR]"
    }
    
    struct LogItem: Identifiable {
        let id = UUID()
        let time: String
        let message: String
        let level: LogLevel
    }
    
    @Published var logs: [LogItem] = []
    private let maxLogs = 300 
    
    // 缓冲池和节流机制
    private var pendingLogs: [LogItem] = []
    private var updateTask: Task<Void, Never>?
    
    private let osLogger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SuperRes", category: "AppLogger")
    
    private let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()
    
    private init() {
        startThrottling()
    }
    
    private func startThrottling() {
        updateTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
                
                guard let self = self else { return }
                
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
    
    // 允许任意线程调用
    nonisolated func log(_ message: String, level: LogLevel = .info) {
        // ⭐️ 修复 1：删除了无用的 timeStr 变量
        
        switch level {
        case .debug: osLogger.debug("\(message)")
        case .info:  osLogger.info("\(message)")
        case .warning: osLogger.warning("\(message)")
        case .error: osLogger.error("\(message)")
        }
        
        Task { @MainActor in
            let item = LogItem(
                time: self.formatTime(Date()),
                message: message,
                level: level
            )
            self.pendingLogs.append(item)
            
            // ⭐️ 修复 2：给缓冲池也加上容量限制，防止主线程卡顿时内存爆炸
            if self.pendingLogs.count > self.maxLogs {
                self.pendingLogs.removeFirst(self.pendingLogs.count - self.maxLogs)
            }
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