// SuperResApp/UI/Screens/RootTabView.swift
// 根标签页：照片 / 实时 / 模型

import SwiftUI

/// 根标签视图
struct RootTabView: View {
    @State private var selectedTab: Tab = .photo

    enum Tab: String {
        case photo = "照片"
        case live = "实时"
        case models = "模型"

        var icon: String {
            switch self {
            case .photo: return "photo.on.rectangle"
            case .live: return "camera.viewfinder"
            case .models: return "square.stack.3d.up"
            }
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            PhotoSuperResView()
                .tabItem {
                    Label(Tab.photo.rawValue, systemImage: Tab.photo.icon)
                }
                .tag(Tab.photo)

            LivePreviewView()
                .tabItem {
                    Label(Tab.live.rawValue, systemImage: Tab.live.icon)
                }
                .tag(Tab.live)

            ModelManagerView()
                .tabItem {
                    Label(Tab.models.rawValue, systemImage: Tab.models.icon)
                }
                .tag(Tab.models)
        }
        .tint(AppTheme.accent)
        // 统一 TabBar 背景：深色模式下与预览区黑色协调，浅色模式下使用系统背景
        .toolbarBackground(Color(UIColor.secondarySystemBackground), for: .tabBar)
        .toolbarBackground(.visible, for: .tabBar)
    }
}

/// 首次启动引导
struct FirstLaunchGuide: View {
    @Binding var isPresented: Bool

    var body: some View {
        VStack(spacing: DesignTokens.spacingLG) {
            Image(systemName: "wand.and.stars")
                .font(.system(size: 48, weight: .light))
                .foregroundColor(AppTheme.accent)

            VStack(spacing: DesignTokens.spacingSM) {
                Text("欢迎使用超分工坊")
                    .font(AppFont.title(weight: .bold))

                Text("内置 PiperSR 和 Real-ESRGAN x4v3，可直接使用。更多模型可在「模型」页下载。")
                    .font(AppFont.body())
                    .foregroundColor(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            PrimaryButton(title: "知道了", action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isPresented = false
                }
            })
        }
        .padding(DesignTokens.spacingXL)
        .frame(maxWidth: 320)
        .background(AppTheme.secondaryGroupedBackground)
        .clipShape(AppShape.card)
        .shadow(color: .black.opacity(0.2), radius: 20)
    }
}
