import SwiftUI
import UIKit

enum DemoPhotoStudioTheme {
    static let accent = Color(red: 0.43, green: 0.78, blue: 0.68)
    static let minimumTouchTarget: CGFloat = 44
    static let previewAspectRatio: CGFloat = 4.0 / 3.0
    static let renderDebounceMilliseconds: Int = 110
    static let undoHistoryLimit: Int = 40
}

struct DemoComparisonPreview: View {
    let originalImage: UIImage
    let editedImage: UIImage
    let mode: PreviewMode
    @Binding var position: CGFloat

    var body: some View {
        GeometryReader { geometry in
            let rect = fittedRect(for: editedImage.size, in: geometry.size)
            ZStack(alignment: .topLeading) {
                imageLayer(editedImage, rect: rect)
                if mode == .original {
                    imageLayer(originalImage, rect: rect)
                } else if mode == .compare {
                    comparisonOriginalLayer(rect: rect)
                    Rectangle().fill(.white).frame(width: 2, height: rect.height)
                        .position(x: rect.minX + rect.width * position, y: rect.midY)
                        .allowsHitTesting(false)
                    Circle().fill(.white)
                        .frame(width: DemoPhotoStudioTheme.minimumTouchTarget,
                               height: DemoPhotoStudioTheme.minimumTouchTarget)
                        .overlay {
                            Image(systemName: "arrow.left.and.right")
                                .font(.system(size: 13, weight: .bold)).foregroundStyle(.black)
                        }
                        .contentShape(Circle())
                        .position(x: rect.minX + rect.width * position, y: rect.midY)
                        .gesture(DragGesture(minimumDistance: 0, coordinateSpace: .named("photo-preview"))
                            .onChanged { value in
                                position = min(max((value.location.x - rect.minX) / max(rect.width, 1), 0), 1)
                            })
                        .accessibilityElement()
                        .accessibilityLabel("前后对比位置")
                        .accessibilityValue("\(Int(position * 100))%")
                        .accessibilityHint("调整原图与编辑效果的分割位置")
                        .accessibilityAdjustableAction { direction in
                            switch direction {
                            case .increment: position = min(1, position + 0.05)
                            case .decrement: position = max(0, position - 0.05)
                            @unknown default: break
                            }
                        }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .topLeading)
            .clipped()
            .coordinateSpace(name: "photo-preview")
        }
    }

    private func imageLayer(_ image: UIImage, rect: CGRect) -> some View {
        Image(uiImage: image).resizable()
            .frame(width: rect.width, height: rect.height)
            .offset(x: rect.minX, y: rect.minY)
    }

    private func comparisonOriginalLayer(rect: CGRect) -> some View {
        Image(uiImage: originalImage).resizable()
            .frame(width: rect.width, height: rect.height)
            .mask(alignment: .leading) {
                Rectangle().frame(width: rect.width * position, height: rect.height)
            }
            .offset(x: rect.minX, y: rect.minY)
    }

    private func fittedRect(for imageSize: CGSize, in container: CGSize) -> CGRect {
        guard imageSize.width > 0, imageSize.height > 0 else { return .zero }
        let scale = min(container.width / imageSize.width, container.height / imageSize.height)
        let size = CGSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return CGRect(x: (container.width - size.width) / 2,
                      y: (container.height - size.height) / 2,
                      width: size.width, height: size.height)
    }
}

private struct DemoAILabFeature: Identifiable {
    let title: String
    let detail: String
    let icon: String
    var id: String { title }
}

struct DemoAILabView: View {
    private let features = [
        DemoAILabFeature(title: "AI 人像修复", detail: "面部细节与肤质优化", icon: "face.smiling"),
        DemoAILabFeature(title: "智能去噪", detail: "降低高 ISO 颗粒与噪点", icon: "circle.lefthalf.filled"),
        DemoAILabFeature(title: "运动去模糊", detail: "恢复运动场景清晰度", icon: "viewfinder"),
        DemoAILabFeature(title: "老照片修复", detail: "划痕修复与褪色还原", icon: "clock.arrow.circlepath")
    ]

    var body: some View {
        List {
            Section {
                ForEach(features) { feature in
                    HStack(spacing: 14) {
                        Image(systemName: feature.icon)
                            .font(.title3).foregroundStyle(DemoPhotoStudioTheme.accent)
                            .frame(width: 42, height: 42)
                            .background(DemoPhotoStudioTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(feature.title).font(.body.weight(.semibold))
                            Text(feature.detail).font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text("规划中").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                            .padding(.horizontal, 9).padding(.vertical, 6)
                            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    }
                    .padding(.vertical, 5)
                }
            } header: {
                Text("后续智能能力")
            } footer: {
                Text("这些功能尚未开放，后续版本会逐项接入，不影响当前照片编辑功能。")
            }
        }
        .navigationTitle("AI 实验室")
        .navigationBarTitleDisplayMode(.inline)
    }
}
