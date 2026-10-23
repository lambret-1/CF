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
    
    // ⭐️ 用于高效、安全地将 CVPixelBuffer 转为图片，兼容 YUV 格式
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // MARK: - FPS 计算

    private var frameTimestamps: [TimeInterval] = []
    private var lastFPSUpdate: TimeInterval = 0
    private var lowPerformanceStartTime: TimeInterval?
    
    // ⭐️ 防止任务堆积：如果上一帧还在处理，直接丢弃当前帧
    private var isProcessingFrame = false

    // MARK: - 生命周期

    func onAppear() async {
        permissionStatus = cameraSession.authorizationStatus
        if permissionStatus == .authorized {
            await start()
        }
    }

    func onDisappear() {
        cameraSession.stop()
        isRunning = false
    }

    func onEnterBackground() {
        cameraSession.stop()
        isRunning = false
    }

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
                // 由于 self 是 @MainActor 修饰，这里的 Task 会自动切回主线程
                Task { [weak self] in
                    await self?.handleFrame(pixelBuffer)
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
        cameraSession.stop()
        isRunning = false
    }

    func requestPermission() async {
        let status = await cameraSession.requestAuthorization()
        permissionStatus = status
        if status == .authorized {
            await start()
        }
    }

    func switchCamera() {
        Task {
            try? await cameraSession.switchCamera()
        }
    }

    // MARK: - 帧处理

    private func handleFrame(_ pixelBuffer: CVPixelBuffer) async {
        // 1. FPS 计算 (无论是否丢帧都要算，反映真实相机帧率)
        let now = Date().timeIntervalSince1970
        frameTimestamps.append(now)
        if frameTimestamps.count > DesignTokens.fpsWindowSize {
            frameTimestamps.removeFirst()
        }
        if now - lastFPSUpdate >= DesignTokens.fpsUpdateInterval {
            updateFPS()
            lastFPSUpdate = now
        }

        // 2. 丢帧机制：如果上一帧的 AI 推理还没结束，直接忽略这一帧
        guard !isProcessingFrame else { return }
        isProcessingFrame = true
        
        // 确保处理完后释放标志位
        defer { isProcessingFrame = false }

        // 3. 安全转换：使用 CIContext 代替手写的 CGContext
        // CIContext 能自动处理 YUV、BGRA 等各种相机原生格式
        let ciImage = CIImage(cvPixelBuffer: pixelBuffer)
        guard let cgImage = ciContext.createCGImage(ciImage, from: ciImage.extent) else {
            return
        }

        // 4. PiperSR 推理（2x）
        do {
            let result = try await superResolver.upscale(
                image: cgImage,
                modelID: "piper-sr-2x",
                tileSize: 512
            )
            
            // 因为类是 @MainActor，这里直接更新 UI
            self.previewImage = UIImage(cgImage: result.outputImage)
        } catch {
            // 实时预览中忽略单帧错误
            print("实时超分推理失败: \(error)")
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
}

// MARK: - CameraSession 扩展
extension CameraSession {
    func setFrameHandler(_ handler: @escaping (CVPixelBuffer, CMTime) -> Void) {
        self.frameHandler = handler
    }
}