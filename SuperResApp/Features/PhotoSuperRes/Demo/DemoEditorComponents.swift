import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

struct DemoEditorSnapshot: Equatable {
    let settings: DemoAdjustmentSettings
    let selectedPreset: DemoPhotoPreset
    let autoEnhanceEnabled: Bool
    let autoEnhanceBaseSettings: DemoAdjustmentSettings?
    let autoEnhanceBasePreset: DemoPhotoPreset?
    let imageTransform: DemoImageTransform
    let markupData: Data?
}

enum CropAction { case reset, rotate, flip, toggleSquare, perspective }

enum PreviewMode { case result, original }

enum EditorTab: String, CaseIterable, Identifiable {
    case adjust, filters, crop, analysis, livePhoto, markup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adjust: "调整"
        case .filters: "滤镜"
        case .crop: "裁剪"
        case .analysis: "识别"
        case .livePhoto: "实况"
        case .markup: "标注"
        }
    }
    var icon: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .filters: "camera.filters"
        case .crop: "crop"
        case .analysis: "viewfinder"
        case .livePhoto: "livephoto"
        case .markup: "pencil.tip.crop.circle"
        }
    }
}

enum AdjustmentControl: String, CaseIterable, Identifiable {
    case auto, exposure, contrast, saturation, vibrance, brightness, highlights, shadows, temperature, tint, sharpness, noiseReduction, vignette
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "自动"
        case .exposure: "曝光"
        case .contrast: "对比度"
        case .saturation: "饱和度"
        case .vibrance: "自然饱和度"
        case .brightness: "亮度"
        case .highlights: "高光"
        case .shadows: "阴影"
        case .temperature: "色温"
        case .tint: "色调"
        case .sharpness: "锐度"
        case .noiseReduction: "降噪"
        case .vignette: "暗角"
        }
    }
    var icon: String {
        switch self {
        case .auto: "wand.and.stars"
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop.fill"
        case .vibrance: "drop"
        case .brightness: "sun.max"
        case .highlights: "sun.max.fill"
        case .shadows: "sun.haze"
        case .temperature: "thermometer.medium"
        case .tint: "circle.lefthalf.filled"
        case .sharpness: "viewfinder"
        case .noiseReduction: "aqi.medium"
        case .vignette: "circle.dashed"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .auto: -2...2
        case .exposure: -2...2
        case .contrast: 0.5...1.8
        case .saturation: 0...2
        case .vibrance: -1...1
        case .brightness: -0.5...0.5
        case .highlights: 0...1
        case .shadows: 0...1
        case .temperature: 2500...10000
        case .tint: -150...150
        case .sharpness: 0...2
        case .noiseReduction: 0...0.1
        case .vignette: -2...2
        }
    }
    var keyPath: WritableKeyPath<DemoAdjustmentSettings, Double> {
        switch self {
        case .auto, .exposure: \.exposure
        case .contrast: \.contrast
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .brightness: \.brightness
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .temperature: \.temperature
        case .tint: \.tint
        case .sharpness: \.sharpness
        case .noiseReduction: \.noiseReduction
        case .vignette: \.vignette
        }
    }
}

struct DemoShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

struct TickMarkSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State var dragStartValue: Double?

    var progress: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let tickSpacing: CGFloat = 12
            let rulerWidth = tickSpacing * 60
            ZStack {
                HStack(spacing: tickSpacing - 1) {
                    ForEach(0..<61, id: \.self) { index in
                        Rectangle()
                            .fill(Color(uiColor: .tertiaryLabel).opacity(index.isMultiple(of: 5) ? 0.72 : 0.42))
                            .frame(width: 1, height: index.isMultiple(of: 5) ? 22 : 12)
                    }
                }
                .frame(width: rulerWidth, alignment: .leading)
                .offset(x: width / 2 - progress * rulerWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: 38)
                    .position(x: width / 2, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                            onEditingChanged(true)
                        }
                        let start = dragStartValue ?? value
                        let delta = Double(gesture.translation.width / max(width, 1)) * (range.upperBound - range.lowerBound)
                        value = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        onEditingChanged(false)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("参数强度")
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 100
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}
