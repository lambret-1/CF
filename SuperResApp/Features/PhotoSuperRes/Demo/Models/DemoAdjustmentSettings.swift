import SwiftUI

/// Adjustment values are consumed by Apple's built-in Core Image filters.
struct DemoAdjustmentSettings: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var highlights: Double = 0
    var shadows: Double = 0
    var temperature: Double = 6500
    var tint: Double = 0
    var sharpness: Double = 0
    var noiseReduction: Double = 0
    var vignette: Double = 0
}

enum DemoPhotoPreset: String, CaseIterable, Identifiable, Equatable {
    case original
    case noir
    case chrome
    case fade
    case instant
    case mono
    case process
    case tonal
    case transfer
    case custom

    var id: String { rawValue }

    /// These identifiers are Apple's built-in Core Image photo-effect filters.
    var filterName: String? {
        switch self {
        case .original, .custom: nil
        case .noir: "CIPhotoEffectNoir"
        case .chrome: "CIPhotoEffectChrome"
        case .fade: "CIPhotoEffectFade"
        case .instant: "CIPhotoEffectInstant"
        case .mono: "CIPhotoEffectMono"
        case .process: "CIPhotoEffectProcess"
        case .tonal: "CIPhotoEffectTonal"
        case .transfer: "CIPhotoEffectTransfer"
        }
    }

    var title: String {
        switch self {
        case .original: "原图"
        case .noir: "黑白"
        case .chrome: "铬黄"
        case .fade: "褪色"
        case .instant: "即时"
        case .mono: "单色"
        case .process: "正片"
        case .tonal: "影调"
        case .transfer: "转印"
        case .custom: "手动调整"
        }
    }

    var subtitle: String {
        switch self {
        case .original: "保留原始图像"
        case .custom: "Apple Core Image 手动调整"
        default: "Apple Core Image 内置滤镜"
        }
    }

    var icon: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .noir, .mono, .tonal: "circle.lefthalf.filled"
        case .chrome, .process: "camera.filters"
        case .fade, .instant, .transfer: "photo"
        case .custom: "slider.horizontal.3"
        }
    }

    var tint: Color {
        switch self {
        case .original, .custom: .secondary
        case .noir, .mono, .tonal: .gray
        case .chrome, .process: .orange
        case .fade, .instant, .transfer: .blue
        }
    }

    var settings: DemoAdjustmentSettings { DemoAdjustmentSettings() }
}


/// Image geometry operations are executed by Core Image.
struct DemoImageTransform: Equatable {
    var quarterTurnsClockwise = 0
    var isHorizontallyFlipped = false
    var usesSquareCrop = false

    static let identity = DemoImageTransform()
}
