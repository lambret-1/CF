// SuperResApp/Features/PhotoSuperRes/PhotoSuperResViewModel.swift
// 照片超分页面视图模型：状态机、选图、推理、保存

import Foundation
import SwiftUI
import PhotosUI
import CoreImage

/// 照片超分页面状态
enum PhotoSuperResState: Equatable {
    case empty
    case imageSelected
    case inferring
    case completed
    case failed(String)
}

/// 照片超分视图模型
@MainActor
final class PhotoSuperResViewModel: ObservableObject {
    // MARK: - 发布属性

    @Published var state: PhotoSuperResState = .empty
    @Published var selectedImage: UIImage?
    @Published var resultImage: UIImage?
    @Published var selectedModelID: String = "realesrgan-x4v3"
    @Published var inferenceProgress: InferenceProgress?
    @Published var isSaving = false
    @Published var showModelPicker = false
    @Published var showPhotoPicker = false
    @Published var photoPickerItem: PhotosPickerItem?
    @Published var compareMode: CompareMode = .slider
    @Published var isShowingOriginal = false
    @Published var saveError: String?

    // MARK: - 依赖

    private let superResolver = SuperResolver.shared
    private let photoLibrary = PhotoLibraryService.shared
    private let manifestLoader = ModelManifestLoader.shared

    // MARK: - 计算属性

    var selectedModelName: String {
        get async {
            await manifestLoader.runtimeInfo(for: selectedModelID)?.name ?? "未知模型"
        }
    }

    var inputSizeText: String {
        guard let image = selectedImage else { return "" }
        return "\(Int(image.size.width))×\(Int(image.size.height))"
    }

    var outputSizeText: String {
        guard let image = resultImage else { return "" }
        return "\(Int(image.size.width))×\(Int(image.size.height))"
    }

    var canInfer: Bool {
        guard selectedImage != nil else { return false }
        switch state {
        case .imageSelected, .completed, .failed:
            return true
        default:
            return false
        }
    }

    var canSave: Bool {
        resultImage != nil && state == .completed
    }

    // MARK: - 选图

    /// 处理 PhotosPicker 选择
    func handlePickerSelection(_ item: PhotosPickerItem?) async {
        guard let item = item else { return }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                state = .failed("图片加载失败")
                return
            }
            guard let image = UIImage(data: data) else {
                state = .failed("图片格式不支持")
                return
            }
            selectedImage = image
            resultImage = nil
            state = .imageSelected
        } catch {
            state = .failed("图片加载失败：\(error.localizedDescription)")
        }
    }

    // MARK: - 推理

    /// 开始超分推理
    func startInference() async {
        guard let uiImage = selectedImage, let cgImage = uiImage.cgImage else {
            state = .failed("无效的图片")
            return
        }

        state = .inferring
        inferenceProgress = nil

        // 触觉反馈
        let impact = UIImpactFeedbackGenerator(style: .medium)
        impact.impactOccurred()

        do {
            let result = try await superResolver.upscale(
                image: cgImage,
                modelID: selectedModelID,
                tileSize: 512
            ) { progress in
                Task { @MainActor in
                    self.inferenceProgress = progress
                }
            }

            resultImage = UIImage(cgImage: result.outputImage)
            state = .completed
            inferenceProgress = nil

            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.success)
        } catch {
            if case InferenceError.cancelled = error {
                state = .imageSelected
            } else if case InferenceError.insufficientMemory = error {
                state = .failed("内存不足，请尝试更小分块或使用轻量模型")
            } else {
                state = .failed(error.localizedDescription)
            }
            inferenceProgress = nil

            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.error)
        }
    }

    /// 取消推理
    func cancelInference() {
        Task {
            await superResolver.cancel()
        }
    }

    /// 重置到空态（取消按钮）
    func reset() {
        Task {
            await superResolver.cancel()
        }
        selectedImage = nil
        resultImage = nil
        inferenceProgress = nil
        state = .empty
        inputSizeText = ""
        outputSizeText = ""
    }

    /// 重新推理
    func resetToImageSelected() {
        resultImage = nil
        state = .imageSelected
    }

    // MARK: - 保存

    /// 保存到相册
    func saveToAlbum() async {
        guard let image = resultImage, let cgImage = image.cgImage else { return }

        isSaving = true
        saveError = nil

        do {
            // 优先 HEIF，失败则 PNG
            if let heifData = await photoLibrary.heifData(from: cgImage) {
                try await photoLibrary.save(data: heifData, type: .heif)
            } else if let pngData = await photoLibrary.pngData(from: cgImage) {
                try await photoLibrary.save(data: pngData, type: .png)
            } else {
                try await photoLibrary.save(cgImage)
            }

            isSaving = false
            ToastManager.shared.show("已保存到相册", type: .success)

            let notification = UINotificationFeedbackGenerator()
            notification.notificationOccurred(.success)
        } catch {
            isSaving = false
            saveError = error.localizedDescription
            ToastManager.shared.show(error.localizedDescription, type: .error)
        }
    }

    // MARK: - 模型选择

    /// 获取可用模型列表
    func availableModels() async -> [ModelRuntimeInfo] {
        let all = await manifestLoader.allRuntimeInfo()
        // 只显示内置和已下载的模型
        return all.filter { $0.isBuiltin || $0.status == .downloaded }
    }

    /// 选择模型
    func selectModel(_ modelID: String) {
        selectedModelID = modelID
        showModelPicker = false
        // 如果已有结果，清除以便重新推理
        if state == .completed {
            resultImage = nil
            state = .imageSelected
        }
    }
}
