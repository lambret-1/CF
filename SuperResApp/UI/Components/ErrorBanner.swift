// SuperResApp/UI/Components/ErrorBanner.swift
// 错误横幅组件

import SwiftUI

/// 错误横幅
struct ErrorBanner: View {
    let title: String
    let message: String
    let actionTitle: String
    let action: () -> Void

    init(
        title: String,
        message: String,
        actionTitle: String = "重试",
        action: @escaping () -> Void
    ) {
        self.title = title
        self.message = message
        self.actionTitle = actionTitle
        self.action = action
    }

    var body: some View {
        ErrorCardView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                HStack(spacing: DesignTokens.spacingXS) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundColor(AppTheme.error)
                        .font(.system(size: 16, weight: .semibold))
                    Text(title)
                        .font(AppFont.body(weight: .semibold))
                        .foregroundColor(AppTheme.primaryText)
                }

                Text(message)
                    .font(AppFont.subhead())
                    .foregroundColor(AppTheme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)

                Button(action: action) {
                    Text(actionTitle)
                        .font(AppFont.subhead(weight: .semibold))
                        .foregroundColor(AppTheme.accent)
                }
                .accessibilityLabel(actionTitle)
            }
        }
    }
}

/// 权限引导卡片
struct PermissionCard: View {
    enum PermissionType {
        case photo
        case camera

        var icon: String {
            switch self {
            case .photo: return "photo.on.rectangle"
            case .camera: return "camera"
            }
        }

        var title: String {
            switch self {
            case .photo: return "需要相册权限"
            case .camera: return "需要相机权限"
            }
        }

        var message: String {
            switch self {
            case .photo: return "需要相册权限才能保存超分后的图片"
            case .camera: return "需要相机权限才能进行实时超分预览"
            }
        }
    }

    let type: PermissionType
    let isDenied: Bool
    let action: () -> Void

    var body: some View {
        CardView {
            VStack(spacing: DesignTokens.spacingSM) {
                Image(systemName: type.icon)
                    .font(.system(size: 32, weight: .light))
                    .foregroundColor(AppTheme.accent)

                VStack(spacing: 4) {
                    Text(type.title)
                        .font(AppFont.body(weight: .semibold))
                    Text(type.message)
                        .font(AppFont.subhead())
                        .foregroundColor(AppTheme.secondaryText)
                        .multilineTextAlignment(.center)
                }

                PrimaryButton(
                    title: isDenied ? "打开设置" : "授权",
                    icon: isDenied ? "gear" : "checkmark",
                    action: action
                )
            }
            .frame(maxWidth: .infinity)
        }
        .accessibilityElement(children: .combine)
    }
}
