// SuperResApp/Features/PhotoSuperRes/PhotoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import CoreImage
import UIKit
import Photos

@MainActor
final class PhotoSuperResViewModel: ObservableObject {
    enum State: Equatable {
        case empty, imageSelected, inferring, completed, failed(String)
    }
    
    @Published var state: State = .empty
    @Published var selectedImage: UIImage?
    @Published var resultImage: UIImage?
    @Published var photoPickerItem: PhotosPickerItem?
    @Published var showPhotoPicker = false
    @Published var showModelPicker = false
    @Published var inputSizeText: String = ""
    @Published var outputSizeText: String = ""
    @Published var inferenceProgress: InferenceProgress?
    @Published var compareMode: CompareMode = .slider
    @Published var isSaving = false
    @Published var canSave = false
    
    @Published var selectedModelID: String = "realesrgan-x4v3" 
    
    // MARK: - 依赖
    private let superResolver = SuperResolver.shared
    private let modelStore = ModelStore.shared
    private let manifestLoader = ModelManifestLoader.shared
    private let ciContext = CIContext()
    
    // MARK: - 处理相册选择
    func handlePickerSelection(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else {
            return
        }
        
        self.selectedImage = image
        self.resultImage = nil
        self.inferenceProgress = nil
        self.canSave = false
        
        self.inputSizeText = "\(Int(image.size.width * image.scale))×\(Int(image.size.height * image.scale))"
        self.outputSizeText = ""
        
        self.state = .imageSelected
    }
    
    // MARK: - 开始推理
    func startInference() async {
        guard let image = selectedImage, let cgImage = image.cgImage else { return }
        
        state = .inferring
        inferenceProgress = nil
        
        do {
            let result = try await superResolver.upscale(
                image: cgImage,
                modelID: selectedModelID,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.inferenceProgress = progress
                    }
                }
            )
            
            self.resultImage = UIImage(cgImage: result.outputImage)
            self.outputSizeText = "\(Int(result.outputSize.width))×\(Int(result.outputSize.height))"
            self.state = .completed
            self.canSave = true
            
        } catch {
            print("推理失败: \(error)")
            self.state = .failed(error.localizedDescription)
        }
    }
    
    // MARK: - 取消推理
    func cancelInference() {
        Task {
            await superResolver.cancel()
            await MainActor.run {
                self.state = .imageSelected
                self.inferenceProgress = nil
            }
        }
    }
    
    // MARK: - 保存到相册
    func saveToAlbum() async {
        guard let result = resultImage else { return }
        isSaving = true
        
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization { status in
                guard status == .authorized || status == .limited else {
                    continuation.resume(returning: false)
                    return
                }
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: result)
                }) { saved, error in
                    if let error = error {
                        print("保存失败: \(error)")
                    }
                    continuation.resume(returning: saved)
                }
            }
        }
        
        if success {
            print("✅ 已保存到相册")
        }
        
        isSaving = false
    }
    
    // MARK: - 重置
    func reset() {
        selectedImage = nil
        resultImage = nil
        photoPickerItem = nil
        inferenceProgress = nil
        inputSizeText = ""
        outputSizeText = ""
        canSave = false
        state = .empty
    }
    
    // MARK: - 模型管理
    func availableModels() async -> [ModelRuntimeInfo] {
        // ⭐️ 修复：使用正确的 allRuntimeInfo()，并加上保底加载逻辑
        var models = await manifestLoader.allRuntimeInfo()
        
        // 如果列表为空，说明清单还没加载，立刻加载一次
        if models.isEmpty {
            try? await manifestLoader.loadFromBundle()
            models = await manifestLoader.allRuntimeInfo()
        }
        
        return models
    }
    
    func selectModel(_ id: String) {
        selectedModelID = id
        showModelPicker = false
    }
}