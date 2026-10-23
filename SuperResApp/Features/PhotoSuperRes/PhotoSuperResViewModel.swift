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
    private let manifestLoader = ModelManifestLoader.shared // ⭐️ 新增依赖
    private let ciContext = CIContext()
    
    // ... 其他方法保持不变 ...

    // MARK: - 模型管理
    func availableModels() async -> [ModelRuntimeInfo] {
        return await manifestLoader.allRuntimeInfo()
    }
    
    func selectModel(_ id: String) {
        selectedModelID = id
        showModelPicker = false
    }
}