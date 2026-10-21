// SuperResApp/Features/ModelManager/StorageUsageFooterView.swift
// 存储用量页脚

import SwiftUI

/// 存储用量页脚
struct StorageUsageFooterView: View {
    let usedBytes: Int64
    let freeBytes: Int64

    var body: some View {
        HStack {
            Image(systemName: "internaldrive")
                .font(.system(size: 12))
                .foregroundColor(AppTheme.tertiaryText)
            Text("已用 \(formatted(usedBytes)) · 可用 \(formatted(freeBytes))")
                .font(AppFont.caption())
                .foregroundColor(AppTheme.tertiaryText)
            Spacer()
        }
        .padding(.horizontal, DesignTokens.pageMargin)
        .padding(.vertical, DesignTokens.spacingSM)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("存储已用 \(formatted(usedBytes))，可用 \(formatted(freeBytes))")
    }

    private func formatted(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
