// SuperResApp/UI/Components/Toast.swift
// Toast 轻提示组件

import SwiftUI

/// Toast 数据模型
struct ToastItem: Identifiable, Equatable {
    let id = UUID()
    let message: String
    let type: ToastType
    let duration: TimeInterval

    enum ToastType {
        case success
        case info
        case error

        var icon: String {
            switch self {
            case .success: return "checkmark.circle.fill"
            case .info: return "info.circle.fill"
            case .error: return "xmark.circle.fill"
            }
        }

        var color: Color {
            switch self {
            case .success: return .green
            case .info: return AppTheme.accent
            case .error: return AppTheme.error
            }
        }
    }

    init(message: String, type: ToastType = .success, duration: TimeInterval = 2.0) {
        self.message = message
        self.type = type
        self.duration = duration
    }
}

/// Toast 管理器
@MainActor
class ToastManager: ObservableObject {
    static let shared = ToastManager()
    @Published private(set) var toasts: [ToastItem] = []

    private init() {}

    func show(_ message: String, type: ToastItem.ToastType = .success, duration: TimeInterval = 2.0) {
        let toast = ToastItem(message: message, type: type, duration: duration)
        // 最多 2 条
        if toasts.count >= 2 {
            toasts.removeFirst()
        }
        toasts.append(toast)

        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            dismiss(toast)
        }
    }

    func dismiss(_ toast: ToastItem) {
        withAnimation(.easeInOut(duration: DesignTokens.animationToast)) {
            toasts.removeAll { $0.id == toast.id }
        }
    }
}

/// Toast 容器视图
struct ToastContainer: ViewModifier {
    @ObservedObject private var manager = ToastManager.shared

    func body(content: Content) -> some View {
        ZStack(alignment: .bottom) {
            content
                .zIndex(0)

            VStack(spacing: DesignTokens.spacingXS) {
                ForEach(manager.toasts) { toast in
                    ToastView(toast: toast)
                        .transition(.move(edge: .bottom).combined(with: .opacity))
                }
            }
            .padding(.bottom, DesignTokens.spacingXL)
            .padding(.horizontal, DesignTokens.pageMargin)
            .zIndex(1)
        }
    }
}

/// 单个 Toast
struct ToastView: View {
    let toast: ToastItem

    var body: some View {
        HStack(spacing: DesignTokens.spacingXS) {
            Image(systemName: toast.type.icon)
                .foregroundColor(toast.type.color)
                .font(.system(size: 16, weight: .semibold))
            Text(toast.message)
                .font(AppFont.subhead())
                .foregroundColor(.white)
        }
        .padding(.horizontal, DesignTokens.spacingSM)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: DesignTokens.radiusMD)
                .fill(Color(red: 0.11, green: 0.11, blue: 0.12).opacity(0.92))
        )
        .shadow(color: .black.opacity(0.2), radius: 8, x: 0, y: 2)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(toast.message)
    }
}

extension View {
    /// 添加 Toast 支持
    func withToast() -> some View {
        modifier(ToastContainer())
    }
}
