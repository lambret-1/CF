// SuperResApp/Features/video/VideoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import AVFoundation
import Photos

// MARK: - 模型元数据（修复 #10：类型化 + 静态表 + 倍数内联）
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

    // MARK: 状态机（修复 #7 / #8 / #9）
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

        /// 模型菜单是否可编辑（修复 #13：保留原产品语义，完成态锁定）
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

    // MARK: Published
    @Published var state: State = .empty
    @Published var progress: Double = 0.0
    @Published var originalVideoURL: URL?
    @Published var resultVideoURL: URL?
    @Published var selectedModelID: String = SuperResModel.defaultModel.id

    // MARK: Private
    private let tempDirectory = FileManager.default.temporaryDirectory
    private var processor: VideoSuperResProcessor?

    /// 代次号：取消 / 重置 / 重新加载时自增；异步回调据此丢弃过期结果（修复 #19）
    private var generation: Int = 0

    // MARK: - 放大倍数（修复 #12：改为配置表推导）
    var currentScaleFactor: Int {
        SuperResModel.scaleFactor(for: selectedModelID)
    }

    // MARK: - 加载相册视频（修复 #7 / #20）
    func handleVideoSelection(_ item: PhotosPickerItem) async {
        guard !state.isBusy || state == .loading else { return }

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

            // 若期间被其他操作覆盖（reset / 另一次选择），丢弃本次结果
            guard state == .loading else {
                try? FileManager.default.removeItem(at: movie.url)
                return
            }

            // 清理旧资源
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
            // 修复 #20：失败时清空旧 URL，避免残留状态误导 UI
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

    // MARK: - 开始处理（修复 #19 / #22）
    func startProcessing() async {
        guard let inputURL = originalVideoURL else { return }
        guard state == .videoSelected || state.isFailed else { return }

        state = .processing
        progress = 0.0

        let gen = generation
        let outputURL = tempDirectory
            .appendingPathComponent("superres_\(Int(Date().timeIntervalSince1970)).mov")
        let newProcessor = VideoSuperResProcessor()
        self.processor = newProcessor

        let scale = currentScaleFactor
        let modelID = selectedModelID
        AppLogger.shared.log(
            "[视频控制] 调用超分引擎，模型: \(modelID)，倍数: \(scale)x",
            isError: false
        )

        do {
            try await newProcessor.processVideo(
                inputURL: inputURL,
                outputURL: outputURL,
                modelID: modelID,
                scaleFactor: scale,
                progressHandler: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        // 修复 #22：NaN / Inf / 越界统一裁剪
                        let safe = p.isFinite ? min(max(p, 0), 1) : 0
                        self.progress = safe
                    }
                }
            )

            // 修复 #19：过期结果（用户已取消 / 重置）直接丢弃
            guard generation == gen else {
                try? FileManager.default.removeItem(at: outputURL)
                return
            }

            self.resultVideoURL = outputURL
            self.progress = 1.0
            self.state = .completed
            self.processor = nil
            AppLogger.shared.log("[视频控制] 视频处理完毕，准备预览。", isError: false)

        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            if generation == gen {
                // 主动取消（cancelProcessing / reset）已设置好目标状态，这里只在意外取消时兜底
                self.state = originalVideoURL != nil ? .videoSelected : .empty
                self.progress = 0.0
                self.processor = nil
            }
            AppLogger.shared.log("[视频控制] 任务被取消。", isError: false)

        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            guard generation == gen else { return }
            self.state = .failed("视频处理失败: \(error.localizedDescription)")
            self.progress = 0.0
            self.processor = nil
            AppLogger.shared.log(
                "[视频控制] 任务异常中止: \(error.localizedDescription)",
                isError: true
            )
        }
    }

    // MARK: - 取消处理（修复 #5 / #6 / #19）
    func cancelProcessing() {
        guard state == .processing else { return }
        generation += 1
        AppLogger.shared.log("[视频控制] 用户点击取消...", isError: false)

        // 先触发 processor 内部取消，再释放引用
        if let p = processor {
            Task { await p.cancel() }
        }
        processor = nil
        progress = 0.0
        state = originalVideoURL != nil ? .videoSelected : .empty
    }

    // MARK: - 保存到相册（修复 #1 / #4）
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

        // 保存失败允许重试；成功也回到 completed（没有其它副作用）
        state = .completed
        return ok
    }

    private func performSave(url: URL) async -> Bool {
        // 优先检查权限，避免无谓写入（修复 #1）
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

    // MARK: - 重置（修复 #5 / #6 / #19）
    func reset() {
        generation += 1

        if let p = processor {
            Task { await p.cancel() }
        }
        processor = nil

        if let url = originalVideoURL { try? FileManager.default.removeItem(at: url) }
        if let url = resultVideoURL { try? FileManager.default.removeItem(at: url) }

        originalVideoURL = nil
        resultVideoURL = nil
        state = .empty
        progress = 0.0
    }
}

// MARK: - 视频传输（修复：保留原扩展名）
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