// SuperResApp/UI/Components/Badge.swift
// 徽章组件：状态、许可证、标签

import SwiftUI

/// 徽章样式
enum BadgeStyle {
    case builtin
    case downloaded
    case nonCommercial
    case wifiOnly
    case cpuSlow
    case warning
    case error
    case info

    var backgroundColor: Color {
        switch self {
        case .builtin: return Color.gray.opacity(0.2)
        case .downloaded: return Color.green.opacity(0.15)
        case .nonCommercial: return AppTheme.warning.opacity(0.15)
        case .wifiOnly: return AppTheme.warning.opacity(0.15)
        case .cpuSlow: return AppTheme.warning.opacity(0.15)
        case .warning: return AppTheme.warning.opacity(0.15)
        case .error: return AppTheme.error.opacity(0.15)
        case .info: return AppTheme.accent.opacity(0.12)
        }
    }

    var foregroundColor: Color {
        switch self {
        case .builtin: return .secondary
        case .downloaded: return .green
        case .nonCommercial: return AppTheme.warning
        case .wifiOnly: return AppTheme.warning
        case .cpuSlow: return AppTheme.warning
        case .warning: return AppTheme.warning
        case .error: return AppTheme.error
        case .info: return AppTheme.accent
        }
    }
}

/// 徽章
struct Badge: View {
    let text: String
    let style: BadgeStyle
    let icon: String?

    init(text: String, style: BadgeStyle, icon: String? = nil) {
        self.text = text
        self.style = style
        self.icon = icon
    }

    var body: some View {
        HStack(spacing: 3) {
            if let icon = icon {
                Image(systemName: icon)
                    .font(.system(size: 9, weight: .semibold))
            }
            Text(text)
                .font(.system(size: 10, weight: .medium))
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(style.backgroundColor)
        .foregroundColor(style.foregroundColor)
        .clipShape(AppShape.badge)
        .accessibilityLabel(text)
    }
}

/// 状态徽章（根据 ModelStatus 自动选择样式）
struct StatusBadge: View {
    let status: ModelStatus

    var body: some View {
        switch status {
        case .builtin:
            Badge(text: "内置", style: .builtin, icon: "checkmark.circle.fill")
        case .downloaded:
            Badge(text: "已下载", style: .downloaded, icon: "checkmark.circle.fill")
        case .notDownloaded:
            Badge(text: "未下载", style: .info, icon: "arrow.down.circle")
        case .queued:
            Badge(text: "排队中", style: .info, icon: "clock")
        case .downloading:
            Badge(text: "下载中", style: .info, icon: "arrow.down")
        case .paused:
            Badge(text: "已暂停", style: .warning, icon: "pause.fill")
        case .compiling:
            Badge(text: "编译中", style: .info, icon: "gear")
        case .failed:
            Badge(text: "失败", style: .error, icon: "exclamationmark.triangle.fill")
        }
    }
}
