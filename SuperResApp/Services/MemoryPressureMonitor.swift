// SuperResApp/Services/MemoryPressureMonitor.swift
// 内存压力监控：监听系统内存警告，通知 ModelStore 驱逐模型

import Foundation
import UIKit

/// 内存压力监控器
actor MemoryPressureMonitor {
    /// 单例
    static let shared = MemoryPressureMonitor()

    /// 内存警告回调
    var onMemoryWarning: (() -> Void)?

    private init() {
        NotificationCenter.default.addObserver(
            forName: UIApplication.didReceiveMemoryWarningNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { [weak self] in
                await self?.handleMemoryWarning()
            }
        }
    }

    private func handleMemoryWarning() {
        onMemoryWarning?()
    }

    /// 获取当前进程可用内存（字节）
    static func availableMemory() -> Int64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
        let kerr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard kerr == KERN_SUCCESS else { return 0 }
        return Int64(info.resident_size)
    }

    /// 获取设备物理内存（字节）
    static func physicalMemory() -> Int64 {
        Int64(ProcessInfo.processInfo.physicalMemory)
    }

    /// 检查是否有足够内存加载指定大小的模型
    /// - Parameter modelSize: 模型大小（字节）
    /// - Parameter multiplier: 内存占用倍数（推理时峰值内存通常是模型的 3-5 倍）
    /// - Returns: 是否足够
    static func hasSufficientMemory(forModelSize modelSize: Int64, multiplier: Double = 4.0) -> Bool {
        let needed = Int64(Double(modelSize) * multiplier)
        let available = os_proc_available_memory()
        return available > needed
    }
}
