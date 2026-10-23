// SuperResApp/App/SuperResApp.swift
// 应用入口

import SwiftUI

@main
struct SuperResApp: App {
    @StateObject private var dependencies = AppDependencies.shared

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