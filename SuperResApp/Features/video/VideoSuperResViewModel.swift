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
    
    // 源文件 URL 和 结果文件 URL
    @Published var originalVideoURL: URL?
    @Published var resultVideoURL: URL?
    
    @Published var selectedModelID: String = "realesrgan-x4v3"
    
    // 临时文件存放地
    private let tempDirectory = FileManager.default.temporaryDirectory
    private var processor: VideoSuperResProcessor?
    
    // MARK: - 处理相册选中的视频
    func handleVideoSelection(_ item: PhotosPickerItem) async {
        state = .processing
        progress = 0.0
        
        do {
            guard let movie = try await item.loadTransferable(type: VideoTransferable.self) else {
                throw NSError(domain: "VideoSR", code: 400, userInfo: [NSLocalizedDescriptionKey: "无法读取视频数据"])
            }
            
            self.originalVideoURL = movie.url
            self.state = .videoSelected
            
        } catch {
            self.state = .failed("视频读取失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 开始处理视频
    func startProcessing() async {
        guard let inputURL = originalVideoURL else { return }
        
        state = .processing
        
        let outputURL = tempDirectory.appendingPathComponent("superres_\(Int(Date().timeIntervalSince1970)).mov")e1970)).mp4")
        self.processor = VideoSuperResProcessor()
        
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
            
        } catch {
            self.state = .failed("视频处理失败: \(error.localizedDescription)")
        }
    }
    
    // MARK: - 取消处理
    func cancelProcessing() {
        Task {
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
        
        let _ = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume(returning: false)
                    return
                }
                
                PHPhotoLibrary.shared().performChanges({
                    let creationRequest = PHAssetCreationRequest.forAsset()
                    let options = PHAssetResourceCreationOptions()
                    options.originalFilename = "SuperRes_Video.mp4"
                    creationRequest.addResource(with: .video, fileURL: resultURL, options: options)
                }) { saved, error in
                    if let error = error {
                        print("保存失败: \(error)")
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

// 辅助结构：用于把 PhotosPickerItem 转成本地 URL
struct VideoTransferable: Transferable {
    let url: URL
    
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(contentType: .movie) { movie in
            SentTransferredFile(movie.url)
        } importing: { received in
            // 把相册里的视频复制到沙盒 tmp 目录，防止文件被系统回收
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent("original_\(UUID().uuidString).mp4")
            try FileManager.default.copyItem(at: received.file, to: copy)
            return Self.init(url: copy)
        }
    }
}