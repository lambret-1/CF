import SwiftUI

struct PhotoEntryView: View {
    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Spacer()
                Image(systemName: "photo.on.rectangle.angled")
                    .font(.system(size: 54, weight: .light))
                    .foregroundStyle(AppTheme.accent)
                Text("照片处理")
                    .font(AppFont.title(weight: .bold))
                Text("选择一种照片处理功能")
                    .font(AppFont.body())
                    .foregroundStyle(AppTheme.secondaryText)

                NavigationLink {
                    PhotoSuperResView()
                } label: {
                    entryButton(
                        title: "高清照片",
                        subtitle: "使用 AI 模型提升照片分辨率",
                        icon: "sparkles"
                    )
                }
                .buttonStyle(.plain)

                NavigationLink {
                    DemoPhotoAutoEnhanceView()
                } label: {
                    entryButton(
                        title: "Demo",
                        subtitle: "使用 iOS 原生自动调整优化照片",
                        icon: "wand.and.stars"
                    )
                }
                .buttonStyle(.plain)
                Spacer()
            }
            .padding(.horizontal, DesignTokens.pageMargin)
            .frame(maxWidth: .infinity)
            .background(AppTheme.background)
            .navigationTitle("照片")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func entryButton(title: String, subtitle: String, icon: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 24, weight: .medium))
                .foregroundStyle(AppTheme.accent)
                .frame(width: 52, height: 52)
                .background(AppTheme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
            VStack(alignment: .leading, spacing: 5) {
                Text(title).font(.headline).foregroundStyle(AppTheme.primaryText)
                Text(subtitle).font(.subheadline).foregroundStyle(AppTheme.secondaryText)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(AppTheme.tertiaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppTheme.secondaryGroupedBackground, in: RoundedRectangle(cornerRadius: 18))
    }
}
