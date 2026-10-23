// SuperResApp/Services/AppLogger.swift

import SwiftUI
import Combine

/// 全局日志管理器，用于在 App 内部显示日志
@MainActor
final class AppLogger: ObservableObject {
    static let shared = AppLogger()
    
    struct LogItem: Identifiable {
        let id = UUID()
        let time = Date()
        let message: String
        let isError: Bool
    }
    
    @Published var logs: [LogItem] = []
    private let maxLogs = 300 // 最多保留 300 条，防止内存爆炸
    
    private init() {}
    
    func log(_ message: String, isError: Bool = false) {
        let item = LogItem(message: message, isError: isError)
        logs.append(item)
        if logs.count > maxLogs {
            logs.removeFirst()
        }
        // 同时打印到 Xcode 控制台（以防万一）
        print(isError ? "❌ \(message)" : "ℹ️ \(message)")
    }
    
    func clear() {
        logs.removeAll()
    }
    
    func copyToClipboard() {
        let text = logs.map { "\($0.time) \($0.isError ? "[ERR]" : "[LOG]") \($0.message)" }.joined(separator: "\n")
        UIPasteboard.general.string = text
    }
}