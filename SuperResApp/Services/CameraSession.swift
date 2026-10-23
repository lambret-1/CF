// SuperResApp/Services/CameraSession.swift
// 相机会话：AVCaptureSession，输出 CVPixelBuffer，支持前后切换、权限管理

import Foundation
import AVFoundation
import UIKit

/// 相机会话，负责采集视频帧并输出 CVPixelBuffer
final class CameraSession: NSObject {
    /// 单例
    static let shared = CameraSession()

    // MARK: - 回调

    /// 帧输出回调
    typealias FrameHandler = (CVPixelBuffer, CMTime) -> Void
    var frameHandler: FrameHandler?

    // MARK: - 属性

    private var captureSession: AVCaptureSession?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var videoInput: AVCaptureDeviceInput?
    private let sessionQueue = DispatchQueue(label: "com.superres.camera.session")
    private let outputQueue = DispatchQueue(label: "com.superres.camera.output")

    /// 当前摄像头位置
    private(set) var currentPosition: AVCaptureDevice.Position = .back

    /// 是否正在运行
    private(set) var isRunning = false

    private override init() {
        super.init()
        // 监听中断
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionWasInterrupted,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleInterruption()
        }
        NotificationCenter.default.addObserver(
            forName: .AVCaptureSessionInterruptionEnded,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.handleInterruptionEnded()
        }
    }

    // MARK: - 权限

    /// 相机权限状态
    var authorizationStatus: AVAuthorizationStatus {
        AVCaptureDevice.authorizationStatus(for: .video)
    }

    /// 请求相机权限
    func requestAuthorization() async -> AVAuthorizationStatus {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .video) { granted in
                continuation.resume(returning: granted ? .authorized : .denied)
            }
        }
    }

    /// 确保有权限
    func ensureAuthorization() async -> Bool {
        let status = authorizationStatus
        switch status {
        case .authorized:
            return true
        case .notDetermined:
            return await requestAuthorization() == .authorized
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - 会话控制

    /// 配置并启动相机
    func start(position: AVCaptureDevice.Position = .back) async throws {
        if isRunning { return }

        let hasPermission = await ensureAuthorization()
        guard hasPermission else {
            throw CameraError.permissionDenied
        }

        currentPosition = position

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.configureSession(position: position)
                    self.captureSession?.startRunning()
                    self.isRunning = true
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// 停止相机
    func stop() {
        guard isRunning else { return }
        sessionQueue.async {
            self.captureSession?.stopRunning()
            self.isRunning = false
        }
    }

    /// 切换前后摄像头
    func switchCamera() async throws {
        guard isRunning else { return }
        let newPosition: AVCaptureDevice.Position = currentPosition == .back ? .front : .back
        currentPosition = newPosition

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            sessionQueue.async {
                do {
                    try self.reconfigureSession(position: newPosition)
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - 配置

    private func configureSession(position: AVCaptureDevice.Position) throws {
        let session = AVCaptureSession()
        session.sessionPreset = .hd1280x720 // 720p 输入，PiperSR 2x 输出 1080p

        // ⭐️ 加上配置事务，保证拓扑图完整
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 1. 输入
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.deviceNotFound
        }

        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.configurationFailed("无法添加相机输入")
        }
        session.addInput(input)
        videoInput = input

        // 2. 输出
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)

        guard session.canAddOutput(output) else {
            throw CameraError.configurationFailed("无法添加视频输出")
        }
        session.addOutput(output)
        videoOutput = output

        // 3. 连接方向 ⭐️ 增加了支持性判断
        if let connection = output.connection(with: .video) {
            if connection.isVideoOrientationSupported {
                connection.videoOrientation = .portrait
            }
            if position == .front && connection.isVideoMirroringSupported {
                connection.isVideoMirrored = true
            }
        }

        captureSession = session
    }

    private func reconfigureSession(position: AVCaptureDevice.Position) throws {
        guard let session = captureSession else { return }

        session.beginConfiguration()
        defer { session.commitConfiguration() }

        // 移除旧输入
        if let oldInput = videoInput {
            session.removeInput(oldInput)
        }

        // 添加新输入
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position) else {
            throw CameraError.deviceNotFound
        }
        let input = try AVCaptureDeviceInput(device: device)
        guard session.canAddInput(input) else {
            throw CameraError.configurationFailed("切换摄像头失败：无法添加输入")
        }
        session.addInput(input)
        videoInput = input

        // 更新镜像
        if let connection = videoOutput?.connection(with: .video) {
            if connection.isVideoMirroringSupported {
                connection.isVideoMirrored = position == .front
            }
        }
    }

    // MARK: - 中断处理

    private func handleInterruption() {
        isRunning = false
    }

    private func handleInterruptionEnded() {
        sessionQueue.async {
            self.captureSession?.startRunning()
            self.isRunning = true
        }
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension CameraSession: AVCaptureVideoDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureVideoDataOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        frameHandler?(pixelBuffer, timestamp)
    }
}

// MARK: - 相机错误

enum CameraError: LocalizedError {
    case permissionDenied
    case deviceNotFound
    case configurationFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有相机权限，请在设置中允许访问相机"
        case .deviceNotFound:
            return "未找到摄像头设备"
        case .configurationFailed(let detail):
            return "相机配置失败：\(detail)"
        }
    }
}