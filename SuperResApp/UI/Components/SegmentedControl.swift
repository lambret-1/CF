// SuperResApp/UI/Components/SegmentedControl.swift
// 分段控件：对比模式切换

import SwiftUI

/// 自定义分段控件
struct SegmentedControl<T: Hashable & CaseIterable>: View where T.AllCases: RandomAccessCollection {
    @Binding var selection: T
    let items: [(T, String, String?)] // (值, 标题, 图标)

    init(selection: Binding<T>, items: [(T, String, String?)]) {
        self._selection = selection
        self.items = items
    }

    var body: some View {
        HStack(spacing: 2) {
            ForEach(items, id: \.0) { item in
                Button(action: { selection = item.0 }) {
                    HStack(spacing: 4) {
                        if let icon = item.2 {
                            Image(systemName: icon)
                                .font(.system(size: 12, weight: .medium))
                        }
                        Text(item.1)
                            .font(.system(size: 12, weight: .medium))
                    }
                    .frame(maxWidth: .infinity)
                    .frame(height: 32)
                    .foregroundColor(selection == item.0 ? .white : AppTheme.secondaryText)
                    .background(
                        RoundedRectangle(cornerRadius: 7)
                            .fill(selection == item.0 ? AppTheme.accent : Color.clear)
                    )
                }
                .accessibilityLabel(item.1)
                .accessibilityAddTraits(selection == item.0 ? [.isSelected] : [])
            }
        }
        .padding(3)
        .background(
            RoundedRectangle(cornerRadius: 9)
                .fill(Color.gray.opacity(0.15))
        )
    }
}

/// 对比模式枚举
enum CompareMode: String, CaseIterable, Hashable {
    case slider = "滑动对比"
    case sideBySide = "并排"
    case original = "原图"

    var icon: String {
        switch self {
        case .slider: return "square.split.1x2"
        case .sideBySide: return "square.split.2x1"
        case .original: return "photo"
        }
    }
}
