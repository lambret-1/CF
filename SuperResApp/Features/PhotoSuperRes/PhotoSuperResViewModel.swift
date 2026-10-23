// SuperResApp/Features/PhotoSuperRes/PhotoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import CoreImage
import UIKit
import Photos
import ImageIO // ⭐️ 新增，用于提取和写入 EXIF

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
    @Published var isFastMode: Bool = false
    
    // ⭐️ 新增：用于保存原图的原始数据（包含 EXIF）
    private var originalImageData: Data?
    
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
        
        // ⭐️ 核心：把包含 EXIF 的原始数据存起来
        self.originalImageData = data
        
        self.selectedImage = image
        self.resultImage = nil
        self.inferenceProgress = nil
        self.canSave = false
        
        let pixelWidth = Int(image.size.width * image.scale)
        let pixelHeight = Int(image.size.height * image.scale)
        self.inputSizeText = "\(pixelWidth)×\(pixelHeight)"
        self.outputSizeText = ""
        
        self.state = .imageSelected
    }
    
    // MARK: - 开始推理
    func startInference() async {
        guard let image = selectedImage, let cgImage = image.cgImage else { return }
        
        state = .inferring
        inferenceProgress = nil
        
        do {
            let finalResultImage: CGImage
            
            if isFastMode {
                finalResultImage = try await superResolver.fastUpscale(
                    image: cgImage,
                    modelID: selectedModelID
                )
                let scaleFactor = 4 
                self.outputSizeText = "\(cgImage.width * scaleFactor)×\(cgImage.height * scaleFactor)"
                
            } else {
                let result = try await superResolver.upscale(
                    image: cgImage,
                    modelID: selectedModelID,
                    progressHandler: { [weak self] progress in
                        Task { @MainActor in
                            self?.inferenceProgress = progress
                        }
                    }
                )
                finalResultImage = result.outputImage
                self.outputSizeText = "\(Int(result.outputSize.width))×\(Int(result.outputSize.height))"
            }
            
            self.resultImage = UIImage(cgImage: finalResultImage)
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
    
    // MARK: - 保存到相册（带 EXIF 元数据）
    func saveToAlbum() async {
        guard let result = resultImage, let cgResult = result.cgImage else { return }
        isSaving = true
        
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization { [weak self] status in
                guard let self = self, (status == .authorized || status == .limited) else {
                    continuation.resume(returning: false)
                    return
                }
                
                // ⭐️ 1. 尝试构造带有原图 EXIF 的新数据
                var dataToSave: Data?
                
                if let originalData = self.originalImageData,
                   let source = CGImageSourceCreateWithData(originalData as CFData, nil),
                   var properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    
                    // 移除原图的尺寸和方向属性（因为超分后尺寸变了，而且 CGImage 已经是正方向的）
                    properties.removeValue(forKey: kCGImagePropertyPixelWidth)
                    properties.removeValue(forKey: kCGImagePropertyPixelHeight)
                    // 强制设为 1 (Up)，防止在相册里显示成侧翻的
                    properties[kCGImagePropertyOrientation] = 1 
                    
                    // 创建一个新的 Data 缓存区
                    let mutableData = NSMutableData()
                    
                    // 使用 JPEG 格式写入（因为 JPEG 对 EXIF 的兼容性最好）
                    if let destination = CGImageDestinationCreateWithData(mutableData, "public.jpeg" as CFString, 1, nil) {
                        // 设置最高画质 (1.0)，避免二次压缩损失画质
                        let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 1.0]
                        
                        // 将新图片和原图的属性一起写入
                        CGImageDestinationAddImage(destination, cgResult, properties as CFDictionary)
                        
                        if CGImageDestinationFinalize(destination) {
                            dataToSave = mutableData as Data
                        }
                    }
                }
                
                // ⭐️ 2. 保存到相册
                PHPhotoLibrary.shared().performChanges({
                    if let finalData = dataToSave {
                        // 如果有带 EXIF 的数据，走 PHAssetCreationRequest
                        let creationRequest = PHAssetCreationRequest.forAsset()
                        let options = PHAssetResourceCreationOptions()
                        options.originalFilename = "SuperRes_\(Int(Date().timeIntervalSince1970)).jpg"
                        creationRequest.addResource(with: .photo, data: finalData, options: options)
                    } else {
                        // 保底方案：如果提取 EXIF 失败，直接存 UIImage
                        PHAssetChangeRequest.creationRequestForAsset(from: result)
                    }
                }) { saved, error in
                    if let error = error {
                        print("保存失败: \(error)")
                    }
                    continuation.resume(returning: saved)
                }
            }
        }
        
        if success {
            print("✅ 已保存到相册（包含原始 EXIF 信息）")
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
        originalImageData = nil // ⭐️ 清理原始数据
    }
    
    // MARK: - 模型管理
    func availableModels() async -> [ModelRuntimeInfo] {
        var models = await manifestLoader.allRuntimeInfo()
        if models.isEmpty {
            try? await manifestLoader.loadFromBundle()
            models = await manifestLoader.allRuntimeInfo()
        }
        return models
    }
    
    func selectModel(_ id: String) {
        selectedModelID = id
        showModelPicker = false
        
        let fastModeSupportedModels = ["realesrgan-x4v3", "realesrgan-x4"]
        if !fastModeSupportedModels.contains(id) {
            isFastMode = false
        }
    }
}