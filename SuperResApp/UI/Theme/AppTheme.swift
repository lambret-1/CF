// SuperResApp/UI/Theme/AppTheme.swift
// 应用主题：颜色、字体、形状

import SwiftUI

/// 应用主题颜色
enum AppTheme {
    // MARK: - 主色
    static let accent = Color.accentColor

    // MARK: - 语义色
    static let warning = Color.orange
    static let error = Color.red
    static let success = Color.green

    // MARK: - 背景
    static let background = Color(UIColor.systemBackground)
    static let secondaryBackground = Color(UIColor.secondarySystemBackground)
    static let groupedBackground = Color(UIColor.systemGroupedBackground)
    static let secondaryGroupedBackground = Color(UIColor.secondarySystemGroupedBackground)

    /// 预览区强制深色背景
    static let previewBackground = Color.black

    // MARK: - 文字
    static let primaryText = Color.primary
    static let secondaryText = Color.secondary
    static let tertiaryText = Color(UIColor.tertiaryLabel)

    // MARK: - 分割线
    static let separator = Color(UIColor.separator)

    // MARK: - FPS 颜色
    static func fpsColor(for fps: Double) -> Color {
        if fps >= DesignTokens.fpsWarningThreshold {
            return .white
        } else if fps >= DesignTokens.fpsDangerThreshold {
            return .yellow
        } else {
            return .red
        }
    }
}

/// 应用字体
enum AppFont {
    static func title(weight: Font.Weight = .semibold) -> Font {
        .system(size: DesignTokens.fontSizeTitle, weight: weight)
    }
    static func body(weight: Font.Weight = .regular) -> Font {
        .system(size: DesignTokens.fontSizeBody, weight: weight)
    }
    static func subhead(weight: Font.Weight = .regular) -> Font {
        .system(size: DesignTokens.fontSizeSubhead, weight: weight)
    }
    static func caption(weight: Font.Weight = .medium) -> Font {
        .system(size: DesignTokens.fontSizeCaption, weight: weight)
    }
    static func tabLabel() -> Font {
        .system(size: DesignTokens.fontSizeTabLabel)
    }
    /// 等宽字体（FPS 显示）
    static func monospaced(size: CGFloat = 13) -> Font {
        .system(size: size, weight: .medium).monospacedDigit()
    }
}

/// 应用形状
enum AppShape {
    static let card = RoundedRectangle(cornerRadius: DesignTokens.cardCornerRadius, style: .continuous)
    static let button = RoundedRectangle(cornerRadius: DesignTokens.buttonCornerRadius, style: .continuous)
    static let badge = RoundedRectangle(cornerRadius: DesignTokens.badgeCornerRadius, style: .continuous)
    static let pill = Capsule()
}
