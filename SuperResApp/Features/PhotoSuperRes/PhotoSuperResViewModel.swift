// SuperResApp/Features/PhotoSuperRes/PhotoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import CoreImage
import UIKit

/// 超分模式
enum CompareMode: String, CaseIterable {
    case slider = "滑动对比"
    case sideBySide = "并排"
    case original = "原图"
}

@MainActor
final class PhotoSuperResViewModel: ObservableObject {
    // MARK: - 状态定义
    enum State: Equatable {
        case empty
        case imageSelected
        case inferring
        case completed
        case failed(String)
    }
    
    // MARK: - 发布属性
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
    
    // 选中的模型 ID
    @Published var selectedModelID: String = "realesrgan-x4v3" 
    
    // MARK: - 依赖
    private let superResolver = SuperResolver.shared
    private let modelStore = ModelStore.shared
    private let photoLibrary = PhotoLibraryService.shared
    
    // 用于图片转换
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
        
        // 记录原图尺寸
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
            // ⭐️ 注意：这里去掉了 tileSize 参数，因为新的 SuperResolver 会自动从模型读取尺寸
            let result = try await superResolver.upscale(
                image: cgImage,
                modelID: selectedModelID,
                progressHandler: { [weak self] progress in
                    Task { @MainActor in
                        self?.inferenceProgress = progress
                    }
                }
            )
            
            // 推理成功
            self.resultImage = UIImage(cgImage: result.outputImage)
            self.outputSizeText = "\(Int(result.outputSize.width))×\(Int(result.outputSize.height))"
            self.state = .completed
            self.canSave = true
            
        } catch {
            // 推理失败
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
        
        do {
            try await photoLibrary.saveImageToAlbum(result)
            // 可以在这里弹一个 Toast 提示成功，因为你项目里似乎有 Toast 组件
        } catch {
            print("保存失败: \(error)")
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
        // 调用你的 ModelStore 获取可用模型
        // 假设你有这个方法
        return (try? await modelStore.availableModels()) ?? []
    }
    
    func selectModel(_ id: String) {
        selectedModelID = id
        showModelPicker = false
    }
}