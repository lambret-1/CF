// SuperResApp/Features/video/VideoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import AVFoundation
import Photos
import UIKit

// MARK: - 模型元数据
struct SuperResModel: Identifiable, Hashable, Sendable {
    let id: String
    let displayName: String
    let scaleFactor: Int

    static let all: [SuperResModel] = [
        .init(id: "realesrgan-x4v3",       displayName: "Real-ESRGAN x4v3 (轻量 4x)",       scaleFactor: 4),
        .init(id: "realesrgan-x4plus",     displayName: "Real-ESRGAN x4plus (高画质 4x)",   scaleFactor: 4),
        .init(id: "realesrgan-ultrasharp", displayName: "Real-ESRGAN UltraSharp (锐化 4x)", scaleFactor: 4),
        .init(id: "realesrgan-x4",         displayName: "Real-ESRGAN x4 (通用 4x)",         scaleFactor: 4),
        .init(id: "piper-sr-2x",           displayName: "PiperSR 2x (极速 2x)",            scaleFactor: 2)
    ]

    static var defaultModel: SuperResModel { all[0] }

    static func displayName(for id: String) -> String {
        all.first { $0.id == id }?.displayName ?? "未知"
    }

    static func scaleFactor(for id: String) -> Int {
        all.first { $0.id == id }?.scaleFactor ?? 4
    }
}

// MARK: - 视频处理模式
enum VideoProcessingMode: String, CaseIterable, Identifiable {
    case superResolution
    case frameInterpolation
    var id: String { rawValue }
    var title: String { self == .superResolution ? "视频超分" : "AI 补帧" }
}

// MARK: - 补帧视频元数据
struct FrameInterpolationVideoMetadata: Equatable {
    let fileName: String
    let duration: TimeInterval
    let width: Int
    let height: Int
    let frameRate: Double
    let fileSizeBytes: Int64
    let codec: String
    let bitRateMbps: Double

    var durationText: String {
        let total = max(0, Int(duration.rounded()))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let seconds = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, seconds) : String(format: "%d:%02d", minutes, seconds)
    }
    var fileSizeText: String {
        let megabytes = Double(fileSizeBytes) / 1_048_576
        return megabytes < 1 ? String(format: "%.0f KB", Double(fileSizeBytes) / 1024) : String(format: "%.1f MB", megabytes)
    }
    var resolutionText: String { "\(width) × \(height)" }
}

// MARK: - 主 ViewModel
@MainActor
final class VideoSuperResViewModel: ObservableObject {


    enum State: Equatable {
        case empty
        case loading
        case videoSelected
        case processing
        case saving
        case completed
        case failed(String)

        var isBusy: Bool {
            switch self {
            case .loading, .processing, .saving: return true
            default: return false
            }
        }

        var canEditModel: Bool {
            switch self {
            case .processing, .saving, .completed: return false
            default: return true
            }
        }

        var isFailed: Bool {
            if case .failed = self { return true }
            return false
        }
    }

    @Published var state: State = .empty
    @Published var progress: Double = 0.0
    @Published var originalVideoURL: URL?
    @Published var resultVideoURL: URL?
    @Published var selectedModelID: String = SuperResModel.defaultModel.id
    @Published var processingMode: VideoProcessingMode = .superResolution
    @Published var interpolationMultiplier: Int = 2
    @Published var fastMode: Bool = false
    @Published var videoMetadata: FrameInterpolationVideoMetadata?

    private let tempDirectory = FileManager.default.temporaryDirectory
    private var processor: VideoSuperResProcessor?
    private var frameInterpolationProcessor: VideoFrameInterpolationProcessor?
    private var generation: Int = 0
    private var interpolationDebugObserver: NSObjectProtocol? = nil

    // ❗️后台任务句柄：beginBackgroundTask 返回值，必须与 endBackgroundTask 一一配对
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var currentScaleFactor: Int {
        SuperResModel.scaleFactor(for: selectedModelID)
    }

    init() {
        // 将 RIFE 模型诊断通知转发到应用内「调试」Tab。
        interpolationDebugObserver = NotificationCenter.default.addObserver(
            forName: Notification.Name("BzDebugInfoUpdated"),
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let info = note.object as? String, !info.isEmpty else { return }
            Task { @MainActor [weak self] in
                // 超分 ViewModel 也存在于首页；只允许补帧 ViewModel 接收 RIFE 诊断，避免重复日志。
                guard let self, self.processingMode == .frameInterpolation else { return }
                AppLogger.shared.log("[补帧模型诊断]\n\(info)", isError: false)
            }
        }
    }

    // MARK: - 后台任务管理
    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }

        backgroundTaskID = UIApplication.shared.beginBackgroundTask(
            withName: "VideoSuperResProcessing"
        ) { [weak self] in
            // ❗️系统即将收回后台时间：先立即 end（防止被系统 kill），
            // 再主动取消处理器，保证 UI 状态机与后台真正执行的逻辑保持一致。
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.log(
                    "[视频控制] ⚠️ 后台执行时间即将耗尽，主动取消以避免被系统强杀",
                    isError: true
                )
                self.endBackgroundTaskIfNeeded()
                self.cancelProcessing()
            }
        }

        if backgroundTaskID == .invalid {
            AppLogger.shared.log("[视频控制] ⚠️ 申请后台任务失败", isError: true)
        } else {
            AppLogger.shared.log(
                "[视频控制] ✅ 已申请后台任务 ID=\(backgroundTaskID.rawValue)",
                isError: false
            )
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
        AppLogger.shared.log(
            "[视频控制] 已结束后台任务 ID=\(id.rawValue)",
            isError: false
        )
    }

    // MARK: - 加载相册视频
    func handleVideoSelection(_ item: PhotosPickerItem) async {
        guard !state.isBusy else {
            AppLogger.shared.log("[视频控制] 忽略选视频请求：当前任务进行中", isError: false)
            return
        }

        state = .loading
        progress = 0.0
        AppLogger.shared.log("[视频控制] 开始加载相册视频数据...", isError: false)

        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                throw NSError(
                    domain: "VideoSR",
                    code: 400,
                    userInfo: [NSLocalizedDescriptionKey: "无法读取视频数据"]
                )
            }

            guard state == .loading else {
                try? FileManager.default.removeItem(at: movie.url)
                return
            }

            if let old = originalVideoURL { try? FileManager.default.removeItem(at: old) }
            if let old = resultVideoURL { try? FileManager.default.removeItem(at: old) }
            resultVideoURL = nil

            let metadata = try await loadVideoMetadata(from: movie.url)
            guard state == .loading else {
                try? FileManager.default.removeItem(at: movie.url)
                return
            }
            self.originalVideoURL = movie.url
            self.videoMetadata = metadata
            self.state = .videoSelected
            AppLogger.shared.log(
                "[AI补帧] 视频读取成功：\(metadata.fileName)，\(metadata.resolutionText)，\(String(format: "%.2f", metadata.frameRate))fps，时长 \(metadata.durationText)，\(metadata.fileSizeText)，编码 \(metadata.codec)，码率 \(String(format: "%.2f", metadata.bitRateMbps))Mbps",
                isError: false
            )
        } catch {
            guard state == .loading else { return }
            self.originalVideoURL = nil
            self.resultVideoURL = nil
            self.videoMetadata = nil
            self.state = .failed("视频读取失败: \(error.localizedDescription)")
            AppLogger.shared.log(
                "[视频控制] 视频读取失败: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - 视频元数据
    private func loadVideoMetadata(from url: URL) async throws -> FrameInterpolationVideoMetadata {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw NSError(domain: "VideoFrameInterpolation", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "找不到视频轨道"])
        }

        async let fpsValue = track.load(.nominalFrameRate)
        async let naturalSizeValue = track.load(.naturalSize)
        async let transformValue = track.load(.preferredTransform)
        async let bitRateValue = track.load(.estimatedDataRate)
        async let descriptionsValue = track.load(.formatDescriptions)
        let (fps, naturalSize, transform, bitRate, descriptions) = try await (
            fpsValue, naturalSizeValue, transformValue, bitRateValue, descriptionsValue
        )
        let displaySize = naturalSize.applying(transform)
        let fileSize = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0) } ?? 0
        let codec = descriptions.first.map { Self.codecName(for: CMFormatDescriptionGetMediaSubType($0)) } ?? "未知"
        let seconds = CMTimeGetSeconds(duration)

        return FrameInterpolationVideoMetadata(
            fileName: url.lastPathComponent,
            duration: seconds.isFinite ? seconds : 0,
            width: Int(abs(displaySize.width)),
            height: Int(abs(displaySize.height)),
            frameRate: Double(fps),
            fileSizeBytes: fileSize,
            codec: codec,
            bitRateMbps: Double(bitRate) / 1_000_000
        )
    }

    private static func codecName(for code: FourCharCode) -> String {
        let bytes: [UInt8] = [
            UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)
        ]
        let value = String(bytes: bytes, encoding: .ascii) ?? "未知"
        switch value {
        case "avc1", "AVC1": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "mp4v": return "MPEG-4"
        default: return value.uppercased()
        }
    }

    // MARK: - 开始处理
    func startProcessing() async {
        guard let inputURL = originalVideoURL else { return }
        guard state == .videoSelected || state.isFailed else { return }

        state = .processing
        progress = 0.0

        // ❗️进入处理前申请后台执行时间（App 在后台时也能继续跑）
        beginBackgroundTaskIfNeeded()

        let gen = generation
        let outputURL = tempDirectory
            .appendingPathComponent("video_result_\(UUID().uuidString).mov")
        let mode = processingMode
        let modelID = selectedModelID
        let scale = currentScaleFactor
        let fastModeEnabled = fastMode
        AppLogger.shared.log(
            mode == .frameInterpolation
                ? "[AI补帧] 调用 RIFE 引擎，倍数：\(interpolationMultiplier)x，快速模式：\(fastModeEnabled ? "开启（静态混合/运动AI）" : "关闭（全帧AI）")"
                : "[视频控制] 调用超分引擎，模型：\(modelID)，倍数：\(scale)x",
            isError: false
        )

        do {
            let progress: @MainActor @Sendable (Double) -> Void = { [weak self] p in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == gen else { return }
                    let safe = p.isFinite ? min(max(p, 0), 1) : 0
                    self.progress = safe
                }
            }
            if mode == .frameInterpolation {
                let newProcessor = VideoFrameInterpolationProcessor()
                frameInterpolationProcessor = newProcessor
                try await newProcessor.processVideo(
                    inputURL: inputURL, outputURL: outputURL,
                    multiplier: interpolationMultiplier, fastMode: fastModeEnabled,
                    progressHandler: progress
                )
                frameInterpolationProcessor = nil
            } else {
                let newProcessor = VideoSuperResProcessor()
                processor = newProcessor
                try await newProcessor.processVideo(inputURL: inputURL, outputURL: outputURL, modelID: modelID, scaleFactor: scale, progressHandler: progress)
                processor = nil
            }

            guard generation == gen else {
                try? FileManager.default.removeItem(at: outputURL)
                endBackgroundTaskIfNeeded()
                return
            }

            self.resultVideoURL = outputURL
            self.progress = 1.0
            self.state = .completed
            self.processor = nil
            endBackgroundTaskIfNeeded()
            AppLogger.shared.log("[视频控制] 视频处理完毕，准备预览。", isError: false)

        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            if generation == gen {
                self.state = originalVideoURL != nil ? .videoSelected : .empty
                self.progress = 0.0
                self.processor = nil
                self.frameInterpolationProcessor = nil
            }
            endBackgroundTaskIfNeeded()
            AppLogger.shared.log("[视频控制] 任务被取消。", isError: false)

        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            guard generation == gen else {
                endBackgroundTaskIfNeeded()
                return
            }
            self.state = .failed("视频处理失败: \(error.localizedDescription)")
            self.progress = 0.0
            self.processor = nil
            self.frameInterpolationProcessor = nil
            endBackgroundTaskIfNeeded()
            AppLogger.shared.log(
                "[视频控制] 任务异常中止: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - 取消处理（唯一允许打断任务的入口）
    func cancelProcessing() {
        guard state == .processing else {
            // 即使状态已不是 processing，也要确保后台句柄被释放（幂等）
            endBackgroundTaskIfNeeded()
            return
        }
        generation += 1
        AppLogger.shared.log("[视频控制] 用户点击取消...", isError: false)

        processor?.cancel()
        frameInterpolationProcessor?.cancel()
        processor = nil
        frameInterpolationProcessor = nil
        progress = 0.0
        state = originalVideoURL != nil ? .videoSelected : .empty
        endBackgroundTaskIfNeeded()
    }

    // MARK: - 保存到相册
    func saveToAlbum() async -> Bool {
        guard let resultURL = resultVideoURL, state == .completed else { return false }

        state = .saving
        AppLogger.shared.log("[视频控制] 准备保存视频到系统相册...", isError: false)

        let ok = await performSave(url: resultURL)

        if ok {
            AppLogger.shared.log("[视频控制] ✅ 视频成功保存到相册！", isError: false)
        } else {
            AppLogger.shared.log("[视频控制] 保存相册失败或被拒绝权限", isError: true)
        }

        state = .completed
        return ok
    }

    private func performSave(url: URL) async -> Bool {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        let granted: PHAuthorizationStatus
        if status == .notDetermined {
            granted = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        } else {
            granted = status
        }
        guard granted == .authorized || granted == .limited else { return false }

        do {
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                let opts = PHAssetResourceCreationOptions()
                opts.originalFilename = "SuperRes_Video.mov"
                req.addResource(with: .video, fileURL: url, options: opts)
            }
            return true
        } catch {
            AppLogger.shared.log(
                "[视频控制] 保存相册失败: \(error.localizedDescription)",
                isError: true
            )
            return false
        }
    }

    // MARK: - 重置
    func reset() {
        guard !state.isBusy else {
            AppLogger.shared.log(
                "[视频控制] reset 被拒绝：任务进行中，必须先点击取消",
                isError: false
            )
            return
        }

        generation += 1

        processor?.cancel()
        frameInterpolationProcessor?.cancel()
        processor = nil
        frameInterpolationProcessor = nil
        endBackgroundTaskIfNeeded()

        if let url = originalVideoURL { try? FileManager.default.removeItem(at: url) }
        if let url = resultVideoURL { try? FileManager.default.removeItem(at: url) }

        originalVideoURL = nil
        resultVideoURL = nil
        videoMetadata = nil
        state = .empty
        progress = 0.0
    }
}

// MARK: - 视频传输
struct VideoTransferable: Transferable {
    let url: URL

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let ext = received.file.pathExtension
            let fileName = "original_\(UUID().uuidString)" + (ext.isEmpty ? ".mp4" : ".\(ext)")
            let copy = FileManager.default.temporaryDirectory
                .appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self.init(url: copy)
        }
    }
}