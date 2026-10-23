// SuperResApp/UI/Screens/RootTabView.swift
// 根标签页：照片 / 视频 / 模型 / 调试

import SwiftUI

/// 根标签视图
struct RootTabView: View {
    @State private var selectedTab: Tab = .photo

    enum Tab: String {
        case photo = "照片"
        case video = "视频" // ⭐️ 将 realtime/live 替换为 video
        case models = "模型"
        case debug = "调试"

        var icon: String {
            switch self {
            case .photo: return "photo.on.rectangle"
            case .video: return "film.stack" // ⭐️ 视频图标
            case .models: return "square.stack.3d.up"
            case .debug: return "ladybug.fill"
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

            // ⭐️ 这里换成我们刚才写的 HomeView (包含 AI补帧 & 视频超分)
            HomeView()
                .tabItem {
                    Label(Tab.video.rawValue, systemImage: Tab.video.icon)
                }
                .tag(Tab.video)

            ModelManagerView()
                .tabItem {
                    Label(Tab.models.rawValue, systemImage: Tab.models.icon)
                }
                .tag(Tab.models)
                
            // 调试日志页面
            DebugConsoleView()
                .tabItem {
                    Label(Tab.debug.rawValue, systemImage: Tab.debug.icon)
                }
                .tag(Tab.debug)
        }
        .tint(AppTheme.accent)
        // 统一 TabBar 背景为系统背景
        .toolbarBackground(AppTheme.background, for: .tabBar)
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
                Text("欢迎使用Ai超分工坊")
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