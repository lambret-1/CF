// SuperResApp/Features/LivePreview/LivePreviewViewModel.swift
// 实时预览视图模型：帧处理、FPS 计算、PiperSR 推理

import Foundation
import SwiftUI
import CoreImage
import AVFoundation

/// 实时预览视图模型
@MainActor
final class LivePreviewViewModel: ObservableObject {
    // MARK: - 发布属性

    @Published private(set) var fps: Double = 0
    @Published private(set) var isRunning = false
    @Published private(set) var permissionStatus: AVAuthorizationStatus = .notDetermined
    @Published private(set) var previewImage: UIImage?
    @Published private(set) var errorMessage: String?
    @Published var showLowPerformanceWarning = false

    // MARK: - 依赖

    private let cameraSession = CameraSession.shared
    private let superResolver = SuperResolver.shared
    private let modelStore = ModelStore.shared

    // MARK: - FPS 计算

    private var frameTimestamps: [TimeInterval] = []
    private var lastFPSUpdate: TimeInterval = 0
    private var lowPerformanceStartTime: TimeInterval?

    // MARK: - 生命周期

    /// 页面出现时启动
    func onAppear() async {
        permissionStatus = await cameraSession.authorizationStatus
        if permissionStatus == .authorized {
            await start()
        }
    }

    /// 页面消失时停止
    func onDisappear() {
        Task {
            await cameraSession.stop()
            isRunning = false
        }
    }

    /// 进入后台
    func onEnterBackground() {
        Task {
            await cameraSession.stop()
            isRunning = false
        }
    }

    /// 回前台
    func onEnterForeground() async {
        if permissionStatus == .authorized {
            await start()
        }
    }

    // MARK: - 启动/停止

    func start() async {
        guard !isRunning else { return }

        do {
            // 设置帧回调
            await cameraSession.setFrameHandler { [weak self] pixelBuffer, _ in
                Task { [weak self] in
                    await self?.processFrame(pixelBuffer)
                }
            }

            try await cameraSession.start(position: .back)
            isRunning = true
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    func stop() {
        Task {
            await cameraSession.stop()
            isRunning = false
        }
    }

    /// 请求相机权限
    func requestPermission() async {
        let status = await cameraSession.requestAuthorization()
        permissionStatus = status
        if status == .authorized {
            await start()
        }
    }

    /// 切换摄像头
    func switchCamera() {
        Task {
            try? await cameraSession.switchCamera()
        }
    }

    // MARK: - 帧处理

    private func processFrame(_ pixelBuffer: CVPixelBuffer) async {
        let now = Date().timeIntervalSince1970

        // FPS 计算
        frameTimestamps.append(now)
        if frameTimestamps.count > DesignTokens.fpsWindowSize {
            frameTimestamps.removeFirst()
        }

        if now - lastFPSUpdate >= DesignTokens.fpsUpdateInterval {
            updateFPS()
            lastFPSUpdate = now
        }

        // 转换为 CGImage
        guard let cgImage = pixelBufferToCGImage(pixelBuffer) else { return }

        // PiperSR 推理（2x）
        do {
            let result = try await superResolver.upscale(
                image: cgImage,
                modelID: "piper-sr-2x",
                tileSize: 512
            )
            await MainActor.run {
                previewImage = UIImage(cgImage: result.outputImage)
            }
        } catch {
            // 实时预览中忽略单帧错误
        }
    }

    private func updateFPS() {
        guard frameTimestamps.count >= 2 else {
            fps = 0
            return
        }
        let first = frameTimestamps.first!
        let last = frameTimestamps.last!
        let duration = last - first
        guard duration > 0 else { return }
        fps = Double(frameTimestamps.count - 1) / duration

        // 低性能检测
        if fps < 15 {
            if lowPerformanceStartTime == nil {
                lowPerformanceStartTime = Date().timeIntervalSince1970
            } else if Date().timeIntervalSince1970 - lowPerformanceStartTime! > 3 {
                showLowPerformanceWarning = true
            }
        } else {
            lowPerformanceStartTime = nil
            showLowPerformanceWarning = false
        }
    }

    // MARK: - 工具

    private func pixelBufferToCGImage(_ pixelBuffer: CVPixelBuffer) -> CGImage? {
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer)

        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue

        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return nil }

        return context.makeImage()
    }
}

// MARK: - CameraSession 扩展

extension CameraSession {
    func setFrameHandler(_ handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
        Task {
            await MainActor.run {
                self.frameHandler = handler
            }
        }
    }
}
