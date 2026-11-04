import SwiftUI

struct DemoAdjustmentSettings: Equatable {
    var exposure: Double = 0
    var brightness: Double = 0
    var contrast: Double = 1
    var saturation: Double = 1
    var temperature: Double = 0
    var highlights: Double = 0
    var shadows: Double = 0
    var sharpness: Double = 0
}

enum DemoPhotoPreset: String, CaseIterable, Identifiable, Equatable {
    case original, portrait, landscape, night, food, custom
    var id: String { rawValue }

    var title: String {
        switch self {
        case .original: "自然原片"
        case .portrait: "人像柔和"
        case .landscape: "风光鲜明"
        case .night: "夜景提亮"
        case .food: "美食暖调"
        case .custom: "自定义"
        }
    }
    var subtitle: String {
        switch self {
        case .original: "还原自然色彩"
        case .portrait: "柔和肤色与光线"
        case .landscape: "增强层次与通透感"
        case .night: "提亮暗部细节"
        case .food: "温暖鲜活的色彩"
        case .custom: "自定义参数"
        }
    }
    var icon: String {
        switch self {
        case .original: "circle.lefthalf.filled"
        case .portrait: "person.crop.square"
        case .landscape: "mountain.2"
        case .night: "moon.stars"
        case .food: "fork.knife"
        case .custom: "slider.horizontal.3"
        }
    }
    var tint: Color {
        switch self {
        case .original, .custom: .secondary
        case .portrait: .pink
        case .landscape: .green
        case .night: .indigo
        case .food: .orange
        }
    }
    var settings: DemoAdjustmentSettings {
        switch self {
        case .original: DemoAdjustmentSettings()
        case .portrait: DemoAdjustmentSettings(exposure: 0.12, brightness: 0.025, contrast: 0.96, saturation: 0.92, temperature: 8, highlights: -0.12, shadows: 0.12, sharpness: 0.15)
        case .landscape: DemoAdjustmentSettings(exposure: 0.08, contrast: 1.18, saturation: 1.22, temperature: -8, highlights: -0.18, shadows: 0.12, sharpness: 0.65)
        case .night: DemoAdjustmentSettings(exposure: 0.55, brightness: 0.08, contrast: 1.08, saturation: 1.05, temperature: 4, highlights: -0.28, shadows: 0.65, sharpness: 0.3)
        case .food: DemoAdjustmentSettings(exposure: 0.16, contrast: 1.1, saturation: 1.18, temperature: 24, highlights: -0.1, shadows: 0.16, sharpness: 0.25)
        case .custom: DemoAdjustmentSettings()
        }
    }
}
