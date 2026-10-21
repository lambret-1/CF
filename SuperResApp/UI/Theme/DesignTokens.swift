// SuperResApp/UI/Theme/DesignTokens.swift
// 设计令牌：间距、圆角、字号、动画时长等常量

import SwiftUI

/// 设计令牌：所有 UI 常量集中管理
enum DesignTokens {
    // MARK: - 间距（8pt 网格）
    static let spacingXXS: CGFloat = 4
    static let spacingXS: CGFloat = 8
    static let spacingSM: CGFloat = 12
    static let spacingMD: CGFloat = 16
    static let spacingLG: CGFloat = 24
    static let spacingXL: CGFloat = 32
    static let spacingXXL: CGFloat = 48

    /// 页面边距
    static let pageMargin: CGFloat = 16

    // MARK: - 圆角
    static let radiusSM: CGFloat = 8
    static let radiusMD: CGFloat = 10
    static let radiusLG: CGFloat = 12
    static let radiusXL: CGFloat = 16
    static let radiusPill: CGFloat = 999

    /// 卡片圆角
    static let cardCornerRadius: CGFloat = 12
    /// 按钮圆角
    static let buttonCornerRadius: CGFloat = 10
    /// 徽章圆角
    static let badgeCornerRadius: CGFloat = 4

    // MARK: - 尺寸
    static let buttonHeight: CGFloat = 50
    static let buttonHeightSmall: CGFloat = 40
    static let cardPadding: CGFloat = 12
    static let cardSpacing: CGFloat = 12
    static let badgeHeight: CGFloat = 18
    static let progressRingSize: CGFloat = 64
    static let progressRingLineWidth: CGFloat = 4

    // MARK: - 字号
    static let fontSizeTitle: CGFloat = 17
    static let fontSizeBody: CGFloat = 15
    static let fontSizeSubhead: CGFloat = 13
    static let fontSizeCaption: CGFloat = 11
    static let fontSizeTabLabel: CGFloat = 10

    // MARK: - 图标尺寸
    static let iconSizeTab: CGFloat = 24
    static let iconSizeButton: CGFloat = 20
    static let iconSizeInline: CGFloat = 16
    static let iconSizeEmpty: CGFloat = 48

    // MARK: - 动画时长
    static let animationPageTransition: Double = 0.3
    static let animationSheet: Double = 0.3
    static let animationImagePick: Double = 0.25
    static let animationCompareSwitch: Double = 0.2
    static let animationDoubleTapZoom: Double = 0.25
    static let animationToast: Double = 0.2
    static let animationProgress: Double = 0.2
    static let animationSkeleton: Double = 1.2
    static let animationLongPress: Double = 0.15

    // MARK: - 预览区
    static let previewMinZoom: CGFloat = 1.0
    static let previewMaxZoom: CGFloat = 8.0
    static let previewDoubleTapZoom: CGFloat = 2.5
    static let compareSliderMinPosition: CGFloat = 0.05
    static let compareSliderMaxPosition: CGFloat = 0.95

    // MARK: - 实时预览
    static let fpsWindowSize: Int = 30
    static let fpsUpdateInterval: TimeInterval = 1.0
    static let fpsWarningThreshold: Double = 25
    static let fpsDangerThreshold: Double = 20
}
