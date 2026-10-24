// SuperResApp/Features/video/VideoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import AVFoundation
import Photos
import UIKit
import Metal

// MARK: - 降采样预设
enum DownscaleOption: String, CaseIterable, Identifiable {
    case p272 = "270p (默认，极速)"
    case p360 = "360p"
    case p480 = "480p"
    case p720 = "720p"
    case none = "不降采样 (原画质)"

    var id: String { rawValue }

    var shortSide: CGFloat? {
        switch self {
        case .p272: return 272
        case .p360: return 360
        case .p480: return 480
        case .p720: return 720
        case .none: return nil // nil 交给 Downscaler 内部处理为原尺寸
        }
    }
}

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
        case empty, loading, videoSelected, processing, saving, completed
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
    @Published var selectedDownscaleOption: DownscaleOption = .p272 // ⭐️ 绑定菜单

    private let tempDirectory = FileManager.default.temporaryDirectory
    private var processor: VideoSuperResProcessor?
    private var generation: Int = 0
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid

    var currentScaleFactor: Int {
        SuperResModel.scaleFactor(for: selectedModelID)
    }

    private init() {}

    private func beginBackgroundTaskIfNeeded() {
        guard backgroundTaskID == .invalid else { return }
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "VideoSuperResProcessing") { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                AppLogger.shared.log("[视频控制] ⚠️ 后台执行时间即将耗尽，主动取消以避免被系统强杀", isError: true)
                self.endBackgroundTaskIfNeeded()
                self.cancelProcessing()
            }
        }
    }

    private func endBackgroundTaskIfNeeded() {
        guard backgroundTaskID != .invalid else { return }
        let id = backgroundTaskID
        backgroundTaskID = .invalid
        UIApplication.shared.endBackgroundTask(id)
    }

    func handleVideoSelection(_ item: PhotosPickerItem) async {
        guard !state.isBusy else { return }

        state = .loading
        progress = 0.0
        AppLogger.shared.log("[视频控制] 开始加载相册视频数据...", isError: false)

        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                throw NSError(domain: "VideoSR", code: 400, userInfo: [NSLocalizedDescriptionKey: "无法读取视频数据"])
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
        } catch {
            guard state == .loading else { return }
            self.originalVideoURL = nil
            self.resultVideoURL = nil
            self.state = .failed("视频读取失败: \(error.localizedDescription)")
        }
    }

    func startProcessing() async {
        guard let inputURL = originalVideoURL else { return }
        guard state == .videoSelected || state.isFailed else { return }

        state = .processing
        progress = 0.0
        beginBackgroundTaskIfNeeded()

        let gen = generation
        let outputURL = tempDirectory.appendingPathComponent("superres_\(Int(Date().timeIntervalSince1970)).mov")
        let newProcessor = VideoSuperResProcessor()
        self.processor = newProcessor

        let scale = currentScaleFactor
        let modelID = selectedModelID
        let downscaleOpt = selectedDownscaleOption

        do {
            // 1. 初始化降采样引擎 (使用用户选择的预设)
            let config = VideoDownscaler.Config(targetShortSide: downscaleOpt.shortSide, alignment: 16)
            let downscaler = try VideoDownscaler(config: config, mtlDevice: MTLCreateSystemDefaultDevice())
            
            // 2. 打开源视频
            let source = try await downscaler.open(inputURL)

            // 3. 动态计算最终尺寸
            let targetOutputSize: CGSize?
            let isPortrait = source.metadata.targetSize.height > source.metadata.targetSize.width
            
            if scale == 4 {
                targetOutputSize = isPortrait ? CGSize(width: 1080, height: 1920) : CGSize(width: 1920, height: 1080)
            } else if scale == 2 {
                targetOutputSize = isPortrait ? CGSize(width: 540, height: 960) : CGSize(width: 960, height: 540)
            } else {
                targetOutputSize = nil
            }

            // 4. 开始超分
            try await newProcessor.processVideo(
                source: source,
                audioSourceURL: inputURL,
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

        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            if generation == gen {
                self.state = originalVideoURL != nil ? .videoSelected : .empty
                self.progress = 0.0
                self.processor = nil
            }
            endBackgroundTaskIfNeeded()
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
        }
    }

    func cancelProcessing() {
        guard state == .processing else {
            endBackgroundTaskIfNeeded()
            return
        }
        generation += 1
        if let p = processor { Task { await p.cancel() } }
        processor = nil
        progress = 0.0
        state = originalVideoURL != nil ? .videoSelected : .empty
        endBackgroundTaskIfNeeded()
    }

    func saveToAlbum() async -> Bool {
        guard let resultURL = resultVideoURL, state == .completed else { return false }
        state = .saving
        let ok = await performSave(url: resultURL)
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
            return false
        }
    }

    func reset() {
        guard !state.isBusy else { return }
        generation += 1
        if let p = processor { Task { await p.cancel() } }
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
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self.init(url: copy)
        }
    }
}