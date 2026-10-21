// SuperResApp/UI/Components/CardView.swift
// 卡片容器组件

import SwiftUI

/// 卡片容器
struct CardView<Content: View>: View {
    let content: Content
    var padding: CGFloat = DesignTokens.cardPadding
    var backgroundColor: Color = AppTheme.secondaryGroupedBackground

    init(padding: CGFloat = DesignTokens.cardPadding,
         backgroundColor: Color = AppTheme.secondaryGroupedBackground,
         @ViewBuilder content: () -> Content) {
        self.padding = padding
        self.backgroundColor = backgroundColor
        self.content = content()
    }

    var body: some View {
        content
            .padding(padding)
            .background(backgroundColor)
            .clipShape(AppShape.card)
    }
}

/// 带左侧指示条的卡片（错误状态用）
struct ErrorCardView<Content: View>: View {
    let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 0) {
            Rectangle()
                .fill(AppTheme.error)
                .frame(width: 3)
            content
                .padding(DesignTokens.cardPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(AppTheme.secondaryGroupedBackground)
        .clipShape(AppShape.card)
    }
}
