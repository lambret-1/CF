// SuperResApp/UI/Components/EmptyStateView.swift
// 空态视图组件

import SwiftUI

/// 空态视图
struct EmptyStateView: View {
    let icon: String
    let title: String
    let subtitle: String?
    let actionTitle: String?
    let action: (() -> Void)?

    init(
        icon: String,
        title: String,
        subtitle: String? = nil,
        actionTitle: String? = nil,
        action: (() -> Void)? = nil
    ) {
        self.icon = icon
        self.title = title
        self.subtitle = subtitle
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            Image(systemName: icon)
                .font(.system(size: DesignTokens.iconSizeEmpty, weight: .light))
                .foregroundColor(AppTheme.tertiaryText)

            VStack(spacing: DesignTokens.spacingXXS) {
                Text(title)
                    .font(AppFont.body(weight: .medium))
                    .foregroundColor(AppTheme.secondaryText)
                if let subtitle = subtitle {
                    Text(subtitle)
                        .font(AppFont.subhead())
                        .foregroundColor(AppTheme.tertiaryText)
                        .multilineTextAlignment(.center)
                }
            }

            if let actionTitle = actionTitle, let action = action {
                SecondaryButton(title: actionTitle, action: action)
                    .padding(.top, DesignTokens.spacingXS)
            }
        }
        .padding(DesignTokens.spacingLG)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
    }
}

/// 虚线框空态（照片页选图用）
struct DashedEmptyStateView: View {
    let icon: String
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: DesignTokens.spacingSM) {
                Image(systemName: icon)
                    .font(.system(size: DesignTokens.iconSizeEmpty, weight: .light))
                    .foregroundColor(AppTheme.tertiaryText)
                Text(title)
                    .font(AppFont.body())
                    .foregroundColor(AppTheme.secondaryText)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(
                RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius)
                    .stroke(style: StrokeStyle(lineWidth: 2, dash: [8, 4]))
                    .foregroundColor(AppTheme.tertiaryText.opacity(0.4))
            )
        }
        .accessibilityLabel(title)
        .accessibilityHint("双击选择图片")
    }
}
