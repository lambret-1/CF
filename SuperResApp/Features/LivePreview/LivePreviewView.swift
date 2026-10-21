// SuperResApp/Features/LivePreview/LivePreviewView.swift
// 实时预览页面：相机实时超分，FPS 显示

import SwiftUI
import AVFoundation

/// 实时预览页面
struct LivePreviewView: View {
    @StateObject private var viewModel = LivePreviewViewModel()

    var body: some View {
        NavigationStack {
            ZStack {
                AppTheme.previewBackground
                    .ignoresSafeArea()

                switch viewModel.permissionStatus {
                case .notDetermined, .denied, .restricted:
                    permissionView

                case .authorized:
                    if viewModel.isRunning {
                        cameraPreview
                    } else {
                        loadingView
                    }

                @unknown default:
                    permissionView
                }
            }
            .navigationTitle("实时超分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.permissionStatus == .authorized && viewModel.isRunning {
                        Button(action: { viewModel.switchCamera() }) {
                            Image(systemName: "arrow.triangle.2.circlepath.camera")
                        }
                        .accessibilityLabel("切换摄像头")
                    }
                }
            }
            .onAppear {
                Task { await viewModel.onAppear() }
            }
            .onDisappear {
                viewModel.onDisappear()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
                viewModel.onEnterBackground()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
                Task { await viewModel.onEnterForeground() }
            }
        }
    }

    // MARK: - 相机预览

    private var cameraPreview: some View {
        ZStack {
            if let image = viewModel.previewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
            } else {
                AppTheme.previewBackground
                ProgressView()
            }

            // 顶部覆盖层：FPS（避开灵动岛/刘海）
            VStack {
                HStack(alignment: .top) {
                    // FPS 指示器（FPS > 0 时显示）
                    if viewModel.fps > 0 {
                        fpsBadge
                    }
                    Spacer()
                }
                Spacer()
            }
            .padding(.top, 8)
            .padding(.horizontal, DesignTokens.pageMargin)

            // 低性能警告
            if viewModel.showLowPerformanceWarning {
                VStack {
                    Spacer()
                    Text("当前设备性能不足，可尝试降低分辨率")
                        .font(AppFont.subhead())
                        .foregroundColor(.white)
                        .padding(.horizontal, DesignTokens.spacingSM)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.6))
                        .clipShape(Capsule())
                        .padding(.bottom, DesignTokens.spacingXL)
                }
            }

            // 底部信息
            VStack {
                Spacer()
                VStack(spacing: 4) {
                    HStack {
                        Image(systemName: "cpu")
                            .font(.system(size: 12))
                        Text("PiperSR 2x (ANE)")
                            .font(AppFont.subhead(weight: .medium))
                        Spacer()
                    }
                    HStack {
                        Text("分辨率：720p → 1080p")
                            .font(AppFont.caption())
                            .foregroundColor(AppTheme.secondaryText)
                        Spacer()
                    }
                }
                .padding(.horizontal, DesignTokens.pageMargin)
                .padding(.bottom, DesignTokens.spacingMD)
                .foregroundColor(AppTheme.primaryText)
            }
        }
    }

    // MARK: - FPS 徽章

    private var fpsBadge: some View {
        HStack(spacing: 4) {
            Image(systemName: "gauge.with.dots.needle.bottom.50percent")
                .font(.system(size: 11, weight: .semibold))
            Text(String(format: "%.0f FPS", viewModel.fps))
                .font(AppFont.monospaced(size: 13))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.ultraThinMaterial)
        .foregroundColor(fpsColor)
        .clipShape(Capsule())
        .accessibilityLabel(String(format: "当前帧率 %.0f", viewModel.fps))
    }

    /// FPS 颜色：>=20 深色，>=15 橙色，<15 红色
    private var fpsColor: Color {
        if viewModel.fps >= 20 {
            return AppTheme.primaryText
        } else if viewModel.fps >= 15 {
            return AppTheme.warning
        } else {
            return AppTheme.error
        }
    }

    // MARK: - 权限引导

    private var permissionView: some View {
        VStack {
            Spacer()
            PermissionCard(
                type: .camera,
                isDenied: viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted,
                action: {
                    if viewModel.permissionStatus == .denied || viewModel.permissionStatus == .restricted {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } else {
                        Task { await viewModel.requestPermission() }
                    }
                }
            )
            .padding(.horizontal, DesignTokens.pageMargin)
            Spacer()
        }
    }

    // MARK: - 加载中

    private var loadingView: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            if let error = viewModel.errorMessage {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 32))
                    .foregroundColor(AppTheme.warning)
                Text("相机启动失败")
                    .font(AppFont.body(weight: .medium))
                    .foregroundColor(AppTheme.primaryText)
                Text(error)
                    .font(AppFont.caption())
                    .foregroundColor(AppTheme.secondaryText)
                    .multilineTextAlignment(.center)
                Button("重试") {
                    Task { await viewModel.start() }
                }
                .buttonStyle(.bordered)
            } else {
                ProgressView()
                Text("启动相机…")
                    .font(AppFont.body())
                    .foregroundColor(AppTheme.primaryText)
            }
        }
        .padding(.horizontal, DesignTokens.pageMargin)
    }
}
