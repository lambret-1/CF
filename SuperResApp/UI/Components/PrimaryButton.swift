// SuperResApp/UI/Components/PrimaryButton.swift
// 主按钮组件：支持默认/禁用/加载中/取消状态

import SwiftUI

/// 主按钮
struct PrimaryButton: View {
    let title: String
    let icon: String?
    let isLoading: Bool
    let isDisabled: Bool
    let isDestructive: Bool
    let action: () -> Void

    init(
        title: String,
        icon: String? = nil,
        isLoading: Bool = false,
        isDisabled: Bool = false,
        isDestructive: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isLoading = isLoading
        self.isDisabled = isDisabled
        self.isDestructive = isDestructive
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.spacingXS) {
                if isLoading {
                    ProgressView()
                        .progressViewStyle(CircularProgressViewStyle(tint: .white))
                        .accessibilityHidden(true)
                }
                if let icon = icon, !isLoading {
                    Image(systemName: icon)
                        .font(.system(size: DesignTokens.iconSizeButton, weight: .semibold))
                }
                Text(title)
                    .font(AppFont.body(weight: .semibold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.buttonHeight)
            .foregroundColor(.white)
            .background(
                backgroundColor
                    .opacity(isDisabled ? 0.5 : 1.0)
            )
            .clipShape(AppShape.button)
        }
        .disabled(isDisabled || isLoading)
        .accessibilityLabel(title)
        .accessibilityHint(isDisabled ? "不可用" : "双击执行")
    }

    private var backgroundColor: Color {
        if isDestructive { return AppTheme.error }
        return AppTheme.accent
    }
}

/// 次要按钮（描边样式）
struct SecondaryButton: View {
    let title: String
    let icon: String?
    let isDisabled: Bool
    let action: () -> Void

    init(
        title: String,
        icon: String? = nil,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.title = title
        self.icon = icon
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: DesignTokens.spacingXS) {
                if let icon = icon {
                    Image(systemName: icon)
                        .font(.system(size: DesignTokens.iconSizeInline, weight: .medium))
                }
                Text(title)
                    .font(AppFont.body(weight: .medium))
            }
            .frame(maxWidth: .infinity)
            .frame(height: DesignTokens.buttonHeightSmall)
            .foregroundColor(AppTheme.accent)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.buttonCornerRadius)
                    .stroke(AppTheme.accent, lineWidth: 1)
            )
        }
        .disabled(isDisabled)
        .accessibilityLabel(title)
    }
}
