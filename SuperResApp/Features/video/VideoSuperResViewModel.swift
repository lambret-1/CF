// SuperResApp/Features/video/VideoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import AVFoundation
import Photos
import UIKit
import Metal

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

// MARK: - 主 ViewModel
@MainActor
final class VideoSuperResViewModel: ObservableObject {

    static let shared = VideoSuperResViewModel()

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

    private let tempDirectory = FileManager.default.temporaryDirectory
    private var processor: VideoSuperResProcessor?
    private var generation: Int = 0

    // ❗️后台任务句柄：beginBackgroundTask 返回值，必须与 endBackgroundTask 一一配对
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var currentScaleFactor: Int {
        SuperResModel.scaleFactor(for: selectedModelID)
    }

    private init() {}

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

            self.originalVideoURL = movie.url
            self.state = .videoSelected
            AppLogger.shared.log(
                "[视频控制] 视频读取成功，准备就绪: \(movie.url.lastPathComponent)",
                isError: false
            )
        } catch {
            guard state == .loading else { return }
            self.originalVideoURL = nil
            self.resultVideoURL = nil
            self.state = .failed("视频读取失败: \(error.localizedDescription)")
            AppLogger.shared.log(
                "[视频控制] 视频读取失败: \(error.localizedDescription)",
                isError: true
            )
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
            .appendingPathComponent("superres_\(Int(Date().timeIntervalSince1970)).mov")
        let newProcessor = VideoSuperResProcessor()
        self.processor = newProcessor

        let scale = currentScaleFactor
        let modelID = selectedModelID
        AppLogger.shared.log(
            "[视频控制] 准备超分引擎，模型: \(modelID)，倍数: \(scale)x",
            isError: false
        )

        do {
            // 1. 初始化降采样引擎
            AppLogger.shared.log("[视频控制] 正在初始化降采样...", isError: false)
            let downscaler = try VideoDownscaler(
                config: .init(targetShortSide: 272, alignment: 16),
                mtlDevice: MTLCreateSystemDefaultDevice()
            )
            
            // 2. 打开源视频，获取帧流
            let source = try await downscaler.open(inputURL)
            AppLogger.shared.log(
                "[视频控制] 降采样就绪，中间尺寸: \(Int(source.metadata.targetSize.width))x\(Int(source.metadata.targetSize.height))",
                isError: false
            )

            // 3. 动态计算最终输出尺寸（自动识别横竖屏，防止拉伸）
            let targetOutputSize: CGSize?
            let isPortrait = source.metadata.targetSize.height > source.metadata.targetSize.width
            
            if scale == 4 {
                // 4x 统一输出 1080p 级别
                targetOutputSize = isPortrait 
                    ? CGSize(width: 1080, height: 1920) // 竖屏 1080p
                    : CGSize(width: 1920, height: 1080) // 横屏 1080p
            } else if scale == 2 {
                // 2x 统一输出 540p 级别
                targetOutputSize = isPortrait 
                    ? CGSize(width: 540, height: 960)   // 竖屏 540p
                    : CGSize(width: 960, height: 540)   // 横屏 540p
            } else {
                targetOutputSize = nil // 其他倍数保持原比例
            }

            // 4. 开始超分与编码
            try await newProcessor.processVideo(
                source: source,
                audioSourceURL: inputURL,       // 传入原始 URL 用于无损直通音频
                outputURL: outputURL,
                modelID: modelID,
                scaleFactor: scale,
                targetOutputSize: targetOutputSize,
                progressHandler: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        let safe = p.isFinite ? min(max(p, 0), 1) : 0
                        self.progress = safe
                    }
                }
            )

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

        if let p = processor {
            Task { await p.cancel() }
        }
        processor = nil
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

        if let p = processor {
            Task { await p.cancel() }
        }
        processor = nil
        endBackgroundTaskIfNeeded()

        if let url = originalVideoURL { try? FileManager.default.removeItem(at: url) }
        if let url = resultVideoURL { try? FileManager.default.removeItem(at: url) }

        originalVideoURL = nil
        resultVideoURL = nil
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