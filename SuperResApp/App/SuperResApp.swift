// SuperResApp/App/SuperResApp.swift
// 应用入口

import SwiftUI

@main
struct SuperResApp: App {
    @StateObject private var dependencies = AppDependencies.shared
    // ⭐️ 用于控制日志弹窗的开关
    @State private var showConsole = false

    var body: some Scene {
        WindowGroup {
            Group {
                if dependencies.isReady {
                    RootTabView()
                        .withToast()
                        .overlay {
                            if dependencies.showFirstLaunchGuide {
                                ZStack {
                                    Color.black.opacity(0.4)
                                        .ignoresSafeArea()
                                    FirstLaunchGuide(isPresented: $dependencies.showFirstLaunchGuide)
                                }
                                .transition(.opacity)
                            }
                        }
                } else {
                    launchScreen
                }
            }
            // ⭐️ 挂载全局悬浮调试按钮
            .overlay(alignment: .bottomTrailing) {
                if dependencies.isReady {
                    Button(action: { showConsole = true }) {
                        Image(systemName: "ladybug.fill")
                            .font(.system(size: 22))
                            .foregroundColor(.white)
                            .padding(14)
                            .background(Color.blue.opacity(0.85))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                    }
                    // 避开底部的 TabBar，具体数值可根据你的 TabBar 高度微调
                    .padding(.trailing, 16)
                    .padding(.bottom, 90)
                }
            }
            // ⭐️ 弹出日志页面
            .sheet(isPresented: $showConsole) {
                DebugConsoleView()
            }
            .task {
                await dependencies.initialize()
            }
        }
    }

    private var launchScreen: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            ProgressView()
                .scaleEffect(1.2)
            Text("正在初始化…")
                .font(AppFont.body())
                .foregroundColor(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(AppTheme.background)
    }
}