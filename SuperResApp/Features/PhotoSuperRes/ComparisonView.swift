// SuperResApp/Features/PhotoSuperRes/ComparisonView.swift
// 对比视图：滑动对比、并排、长按原图

import SwiftUI

/// 对比视图
struct ComparisonView: View {
    let originalImage: UIImage
    let resultImage: UIImage
    @Binding var mode: CompareMode
    @Binding var sliderPosition: CGFloat
    @Binding var isShowingOriginal: Bool
    @Binding var zoomScale: CGFloat

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                switch mode {
                case .slider:
                    sliderComparison(in: geometry.size)
                case .sideBySide:
                    sideBySideComparison(in: geometry.size)
                case .original:
                    originalOnly
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(AppTheme.previewBackground)
        }
    }

    // MARK: - 滑动对比

    private func sliderComparison(in size: CGSize) -> some View {
        ZStack {
            // 底层：超分结果（完整显示）
            Image(uiImage: isShowingOriginal ? originalImage : resultImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width, height: size.height)

            // 上层：原图（被裁剪到滑块左侧）
            if !isShowingOriginal {
                Image(uiImage: originalImage)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(width: size.width, height: size.height)
                    .mask(
                        Rectangle()
                            .frame(width: size.width * sliderPosition, height: size.height)
                            .position(x: size.width * sliderPosition / 2, y: size.height / 2)
                    )

                // 分割线
                Rectangle()
                    .fill(Color.white)
                    .frame(width: 2, height: size.height)
                    .position(x: size.width * sliderPosition, y: size.height / 2)
                    .shadow(color: .black.opacity(0.5), radius: 2, x: 0, y: 0)

                // 上下手柄
                VStack {
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                    Spacer()
                    Circle()
                        .fill(Color.white)
                        .frame(width: 8, height: 8)
                        .shadow(color: .black.opacity(0.5), radius: 2)
                }
                .position(x: size.width * sliderPosition, y: size.height / 2)

                // 拖拽手势
                Color.clear
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                let newPosition = value.location.x / size.width
                                sliderPosition = min(
                                    max(newPosition, DesignTokens.compareSliderMinPosition),
                                    DesignTokens.compareSliderMaxPosition
                                )
                            }
                    )
            }
        }
        // 长按显示原图
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.2)
                .onEnded { _ in
                    isShowingOriginal = true
                    let impact = UIImpactFeedbackGenerator(style: .light)
                    impact.impactOccurred()
                }
                .sequenced(before: DragGesture(minimumDistance: 0).onEnded { _ in
                    isShowingOriginal = false
                })
        )
    }

    // MARK: - 并排对比

    private func sideBySideComparison(in size: CGSize) -> some View {
        HStack(spacing: 1) {
            Image(uiImage: originalImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width / 2 - 0.5, height: size.height)

            Rectangle()
                .fill(Color.white.opacity(0.5))
                .frame(width: 1)

            Image(uiImage: resultImage)
                .resizable()
                .aspectRatio(contentMode: .fit)
                .frame(width: size.width / 2 - 0.5, height: size.height)
        }
    }

    // MARK: - 仅原图

    private var originalOnly: some View {
        Image(uiImage: originalImage)
            .resizable()
            .aspectRatio(contentMode: .fit)
    }
}
