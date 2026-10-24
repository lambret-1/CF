// SuperResApp/Features/video/VideoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import AVFoundation
import Photos

@MainActor
final class VideoSuperResViewModel: ObservableObject {
    enum State: Equatable {
        case empty, videoSelected, processing, completed, failed(String)
    }
    
    @Published var state: State = .empty
    @Published var progress: Double = 0.0
    
    @Published var originalVideoURL: URL?
    @Published var resultVideoURL: URL?
    
    @Published var selectedModelID: String = "realesrgan-x4v3"
    
    private let tempDirectory = FileManager.default.temporaryDirectory
    private var processor: VideoSuperResProcessor?
    
    // MARK: - 处理相册选中的视频
    func handleVideoSelection(_ item: PhotosPickerItem) async {
        state = .processing
        progress = 0.0
        AppLogger.shared.log("[视频控制] 开始加载相册视频数据...", isError: false)
        
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                throw NSError(domain: "VideoSR", code: 400, userInfo: [NSLocalizedDescriptionKey: "无法读取视频数据"])
            }
            
            self.originalVideoURL = movie.url
            self.state = .videoSelected
            AppLogger.shared.log("[视频控制] 视频读取成功，准备就绪: \(movie.url.lastPathComponent)", isError: false)
            
        } catch {
            self.state = .failed("视频读取失败: \(error.localizedDescription)")
            AppLogger.shared.log("[视频控制] 视频读取失败: \(error.localizedDescription)", isError: true)
        }
    }
    
    // MARK: - 开始处理视频
    func startProcessing() async {
        guard let inputURL = originalVideoURL else { return }
        
        state = .processing
        progress = 0.0
        
        let outputURL = tempDirectory.appendingPathComponent("superres_\(Int(Date().timeIntervalSince1970)).mov")
        self.processor = VideoSuperResProcessor()
        
        AppLogger.shared.log("[视频控制] 调用超分引擎，使用模型: \(selectedModelID)", isError: false)
        
        do {
            try await processor?.processVideo(
                inputURL: inputURL,
                outputURL: outputURL,
                modelID: selectedModelID,
                scaleFactor: 4,
                progressHandler: { [weak self] p in
                    Task { @MainActor in
                        self?.progress = p
                    }
                }
            )
            
            self.resultVideoURL = outputURL
            self.state = .completed
            AppLogger.shared.log("[视频控制] 视频处理完毕，准备预览。", isError: false)
            
        } catch {
            self.state = .failed("视频处理失败: \(error.localizedDescription)")
            // 这个错误通常已经在 Processor 里打过了，但再补一条也无妨
            AppLogger.shared.log("[视频控制] 任务异常中止: \(error.localizedDescription)", isError: true)
        }
    }
    
    // MARK: - 取消处理
    func cancelProcessing() {
        Task {
            AppLogger.shared.log("[视频控制] 用户点击取消...", isError: false)
            await processor?.cancel()
            await MainActor.run {
                self.state = .videoSelected
                self.progress = 0.0
            }
        }
    }
    
    // MARK: - 保存视频到相册
    func saveToAlbum() async {
        guard let resultURL = resultVideoURL else { return }
        
        AppLogger.shared.log("[视频控制] 准备保存视频到系统相册...", isError: false)
        
        let _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized || status == .limited else {
                    AppLogger.shared.log("[视频控制] 相册权限被拒绝", isError: true)
                    continuation.resume(returning: false)
                    return
                }
                
                PHPhotoLibrary.shared().performChanges({
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "SuperRes_Video.mov"
                    creationRequest.addResource(with: .video, fileURL: resultURL, options: options)
                }) { saved, error in
                    if let error = error {
                        AppLogger.shared.log("[视频控制] 保存相册失败: \(error.localizedDescription)", isError: true)
                    } else if saved {
                        AppLogger.shared.log("[视频控制] ✅ 视频成功保存到相册！", isError: false)
                    }
                    continuation.resume(returning: saved)
                }
            }
        }
    }
    
    // MARK: - 重置
    func reset() {
        if let url = originalVideoURL { try? FileManager.default.removeItem(at: url) }
        if let url = resultVideoURL { try? FileManager.default.removeItem(at: url) }
        
        originalVideoURL = nil
        resultVideoURL = nil
        state = .empty
        progress = 0.0
    }
}

// 辅助结构保持不变
struct VideoTransferable: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("original_\(UUID().uuidString).mp4")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self.init(url: copy)
        }
    }
}