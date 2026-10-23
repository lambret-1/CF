// SuperResApp/Features/PhotoSuperRes/PhotoSuperResViewModel.swift

import SwiftUI
import PhotosUI
import CoreImage
import UIKit
import Photos
import ImageIO

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
    
    // ⭐️ 新增：用于在 UI 上展示保存成功的反馈
    @Published var saveSuccessMessage: String? = nil
    
    @Published var selectedModelID: String = "realesrgan-x4v3" 
    @Published var isFastMode: Bool = false
    
    // 用于保存原图的原始数据（包含 EXIF）
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
        
        self.originalImageData = data
        self.selectedImage = image
        self.resultImage = nil
        self.inferenceProgress = nil
        self.canSave = false
        self.saveSuccessMessage = nil
        
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
        saveSuccessMessage = nil
        
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
    
    // MARK: - 保存到相册（彻底修复相册看不见的问题）
    func saveToAlbum() async {
        guard let result = resultImage, let cgResult = result.cgImage else { return }
        isSaving = true
        saveSuccessMessage = nil
        
        let success = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            PHPhotoLibrary.requestAuthorization { [weak self] status in
                guard let self = self, (status == .authorized || status == .limited) else {
                    continuation.resume(returning: false)
                    return
                }
                
                // 1. 准备临时文件路径（用 URL 存相册是解决“看不见”的最优解）
                let tempDirectory = FileManager.default.temporaryDirectory
                let tempURL = tempDirectory.appendingPathComponent("SuperRes_\(Int(Date().timeIntervalSince1970)).jpg")
                
                // 2. 准备 EXIF 属性
                var properties: [CFString: Any] = [:]
                if let originalData = self.originalImageData,
                   let source = CGImageSourceCreateWithData(originalData as CFData, nil),
                   let originalProps = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
                    
                    properties = originalProps
                    
                    // 清理可能导致相册解析失败的冲突属性
                    if var tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
                        tiff.removeValue(forKey: kCGImagePropertyTIFFOrientation)
                        properties[kCGImagePropertyTIFFDictionary] = tiff
                    }
                    if var exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] {
                        exif.removeValue(forKey: kCGImagePropertyExifPixelXDimension)
                        exif.removeValue(forKey: kCGImagePropertyExifPixelYDimension)
                        properties[kCGImagePropertyExifDictionary] = exif
                    }
                    // 强制设置正确的方向
                    properties[kCGImagePropertyOrientation] = 1
                }
                
                // 3. 写入临时文件
                if let destination = CGImageDestinationCreateWithURL(tempURL as CFURL, "public.jpeg" as CFString, 1, nil) {
                    let options: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: 0.95]
                    CGImageDestinationAddImage(destination, cgResult, properties as CFDictionary)
                    
                    if CGImageDestinationFinalize(destination) {
                        // 4. 文件生成成功，调用相册保存（使用 fileURL 方式）
                        PHPhotoLibrary.shared().performChanges({
                            let creationRequest = PHAssetCreationRequest.forAsset()
                            let options = PHAssetResourceCreationOptions()
                            options.originalFilename = tempURL.lastPathComponent
                            creationRequest.addResource(with: .photo, fileURL: tempURL, options: options)
                        }) { saved, error in
                            // 保存完毕后，删掉临时文件
                            try? FileManager.default.removeItem(at: tempURL)
                            
                            if let error = error {
                                print("保存失败: \(error)")
                            }
                            continuation.resume(returning: saved)
                        }
                        return
                    }
                }
                
                // 如果上面生成文件失败了，走最原始的降级方案
                PHPhotoLibrary.shared().performChanges({
                    PHAssetChangeRequest.creationRequestForAsset(from: result)
                }) { saved, error in
                    continuation.resume(returning: saved)
                }
            }
        }
        
        if success {
            saveSuccessMessage = "照片已成功保存到相册"
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
        originalImageData = nil
        saveSuccessMessage = nil
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