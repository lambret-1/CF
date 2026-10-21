// SuperResApp/Features/ModelManager/ModelCardView.swift
// 模型卡片：显示名称、体积、许可证、状态、操作按钮

import SwiftUI

/// 模型卡片
struct ModelCardView: View {
    let model: ModelRuntimeInfo
    let onDownload: () -> Void
    let onPause: () -> Void
    let onResume: () -> Void
    let onDelete: () -> Void
    let onRetry: () -> Void

    var body: some View {
        CardView {
            VStack(alignment: .leading, spacing: DesignTokens.spacingXS) {
                // 标题行
                HStack(alignment: .top, spacing: DesignTokens.spacingXS) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.name)
                            .font(AppFont.body(weight: .semibold))
                            .lineLimit(1)

                        // 描述行
                        HStack(spacing: 6) {
                            Text(model.formattedSize)
                                .font(AppFont.caption())
                                .foregroundColor(AppTheme.tertiaryText)
                            Text("·")
                                .font(AppFont.caption())
                                .foregroundColor(AppTheme.tertiaryText)
                            Text(model.license)
                                .font(AppFont.caption())
                                .foregroundColor(AppTheme.tertiaryText)
                                .lineLimit(1)
                        }
                    }

                    Spacer()

                    // 右侧状态/操作
                    rightControl
                }

                // 标签行
                tagRow

                // 下载进度
                if model.status == .downloading {
                    downloadProgressBar
                }

                // 失败原因
                if let reason = model.failureReason, model.status == .failed {
                    Text(reason)
                        .font(AppFont.caption())
                        .foregroundColor(AppTheme.error)
                        .lineLimit(2)
                }

                // 备注
                if let note = model.note {
                    Text(note)
                        .font(.system(size: 10))
                        .foregroundColor(AppTheme.tertiaryText)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(model.name)，\(model.status.rawValue)")
    }

    // MARK: - 右侧控件

    @ViewBuilder
    private var rightControl: some View {
        switch model.status {
        case .builtin:
            Badge(text: "内置", style: .builtin, icon: "checkmark.circle.fill")

        case .notDownloaded:
            Button(action: onDownload) {
                Text("下载")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(AppTheme.accent)
                    .clipShape(Capsule())
            }
            .accessibilityLabel("下载 \(model.name)")

        case .queued:
            Text("排队中")
                .font(AppFont.caption())
                .foregroundColor(AppTheme.secondaryText)

        case .downloading:
            DownloadProgressView(
                progress: model.downloadProgress,
                downloadedText: model.formattedDownloaded,
                isPaused: false,
                onPause: onPause,
                onResume: onResume
            )

        case .paused:
            Button(action: onResume) {
                Text("继续")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().stroke(AppTheme.accent, lineWidth: 1)
                    )
            }
            .accessibilityLabel("继续下载 \(model.name)")

        case .compiling:
            HStack(spacing: 4) {
                ProgressView()
                    .scaleEffect(0.7)
                Text("编译中")
                    .font(AppFont.caption())
                    .foregroundColor(AppTheme.secondaryText)
            }

        case .downloaded:
            Button(action: onDelete) {
                Text("删除")
                    .font(AppFont.caption(weight: .medium))
                    .foregroundColor(AppTheme.error)
            }
            .accessibilityLabel("删除 \(model.name)")

        case .failed:
            Button(action: onRetry) {
                Text("重试")
                    .font(AppFont.caption(weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule().stroke(AppTheme.accent, lineWidth: 1)
                    )
            }
            .accessibilityLabel("重试下载 \(model.name)")
        }
    }

    // MARK: - 标签行

    @ViewBuilder
    private var tagRow: some View {
        HStack(spacing: 4) {
            if model.isNonCommercial {
                Badge(text: "非商用", style: .nonCommercial, icon: "exclamationmark.triangle")
            }
            if model.wifiOnly {
                Badge(text: "仅 Wi-Fi", style: .wifiOnly, icon: "wifi")
            }
            if model.isCPUSlow {
                Badge(text: "CPU 较慢", style: .cpuSlow, icon: "timer")
            }
            if model.status == .downloaded {
                Badge(text: "已下载", style: .downloaded, icon: "checkmark.circle.fill")
            }
        }
    }

    // MARK: - 下载进度条

    private var downloadProgressBar: some View {
        VStack(alignment: .leading, spacing: 2) {
            ProgressView(value: model.downloadProgress)
                .tint(AppTheme.accent)
            Text("\(Int(model.downloadProgress * 100))% · \(model.formattedDownloaded) / \(model.formattedSize)")
                .font(.system(size: 10))
                .foregroundColor(AppTheme.tertiaryText)
        }
    }
}
