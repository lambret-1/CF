// SuperResApp/UI/Components/ProgressRing.swift
// 进度环组件：显示推理/下载进度

import SwiftUI

/// 进度环
struct ProgressRing: View {
    let progress: Double
    let size: CGFloat
    let lineWidth: CGFloat
    let showPercentage: Bool

    init(
        progress: Double,
        size: CGFloat = DesignTokens.progressRingSize,
        lineWidth: CGFloat = DesignTokens.progressRingLineWidth,
        showPercentage: Bool = true
    ) {
        self.progress = min(max(progress, 0), 1)
        self.size = size
        self.lineWidth = lineWidth
        self.showPercentage = showPercentage
    }

    var body: some View {
        ZStack {
            // 背景环
            Circle()
                .stroke(Color.white.opacity(0.3), lineWidth: lineWidth)

            // 进度环
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.white, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.linear(duration: DesignTokens.animationProgress), value: progress)

            // 百分比文字
            if showPercentage {
                Text("\(Int(progress * 100))%")
                    .font(AppFont.body(weight: .semibold))
                    .foregroundColor(.white)
                    .monospacedDigit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityElement(children: .ignore)
        .accessibilityValue("已完成 \(Int(progress * 100))%")
    }
}

/// 下载进度环（带暂停按钮）
struct DownloadProgressView: View {
    let progress: Double
    let downloadedText: String
    let isPaused: Bool
    let onPause: () -> Void
    let onResume: () -> Void

    var body: some View {
        HStack(spacing: DesignTokens.spacingSM) {
            ProgressRing(progress: progress, size: 32, lineWidth: 3, showPercentage: false)
                .foregroundColor(.white)

            VStack(alignment: .leading, spacing: 2) {
                Text("\(Int(progress * 100))%")
                    .font(AppFont.caption())
                    .foregroundColor(AppTheme.secondaryText)
                Text(downloadedText)
                    .font(.system(size: 10))
                    .foregroundColor(AppTheme.tertiaryText)
            }

            Button(action: isPaused ? onResume : onPause) {
                Image(systemName: isPaused ? "play.fill" : "pause.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(AppTheme.accent)
                    .frame(width: 32, height: 32)
            }
            .accessibilityLabel(isPaused ? "继续下载" : "暂停下载")
        }
    }
}
