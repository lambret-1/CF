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
    
    // ⭐️ 新增：极速模式开关状态，供 View 双向绑定
    @Published var isFastMode: Bool = false
    
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
        
        // 获取真实像素尺寸
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
            
            // ⭐️ 核心修改：根据是否极速模式，走不同的底层方法
            if isFastMode {
                // 极速模式：走 DirectStretch 直接拉伸
                finalResultImage = try await superResolver.fastUpscale(
                    image: cgImage,
                    modelID: selectedModelID
                )
                
                // 手动更新一下输出尺寸（因为 fastUpscale 只返回图片）
                let scaleFactor = 4 // 假设是 x4 模型，如果你的模型不定，这里可以通过其他方式获取
                self.outputSizeText = "\(cgImage.width * scaleFactor)×\(cgImage.height * scaleFactor)"
                
            } else {
                // 高质量模式：走 Tiling / Piper 切块
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
    }
}
// SuperResApp/Features/PhotoSuperRes/PhotoSuperResView.swift

import SwiftUI
import PhotosUI

struct PhotoSuperResView: View {
    @StateObject private var viewModel = PhotoSuperResViewModel()
    @State private var sliderPosition: CGFloat = 0.5
    @State private var isShowingOriginal = false
    @State private var zoomScale: CGFloat = 1.0
    @State private var availableModels: [ModelRuntimeInfo] = []
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                previewArea
                    .frame(maxWidth: .infinity)
                
                if viewModel.state == .completed {
                    compareControls
                        .padding(.horizontal, DesignTokens.pageMargin)
                        .padding(.vertical, DesignTokens.spacingXS)
                }
                
                if viewModel.state != .empty {
                    modelInfoSection
                }
                
                if viewModel.state != .empty {
                    bottomActions
                        .padding(.horizontal, DesignTokens.pageMargin)
                        .padding(.bottom, DesignTokens.spacingMD)
                }
            }
            .background(AppTheme.background)
            .navigationTitle("照片超分")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    if viewModel.state != .empty {
                        Button("取消") { viewModel.reset() }
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.canSave {
                        Button(action: { Task { await viewModel.saveToAlbum() } }) {
                            if viewModel.isSaving {
                                ProgressView()
                            } else {
                                Text("保存").fontWeight(.semibold)
                            }
                        }
                    }
                }
            }
            .photosPicker(
                isPresented: $viewModel.showPhotoPicker,
                selection: $viewModel.photoPickerItem,
                matching: .images
            )
            .onChange(of: viewModel.photoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    await viewModel.handlePickerSelection(newItem)
                }
            }
            .sheet(isPresented: $viewModel.showModelPicker) {
                modelPickerSheet
            }
            .task {
                availableModels = await viewModel.availableModels()
            }
        }
    }
    
    // MARK: - 预览区
    @ViewBuilder
    private var previewArea: some View {
        GeometryReader { geometry in
            ZStack {
                AppTheme.previewBackground.ignoresSafeArea()
                
                switch viewModel.state {
                case .empty:
                    Button(action: { viewModel.showPhotoPicker = true }) {
                        EmptyStateView(
                            icon: "photo.on.rectangle",
                            title: "从相册选择图片",
                            action: {}
                        )
                        .padding(.horizontal, DesignTokens.pageMargin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    
                case .imageSelected, .failed:
                    if let image = viewModel.selectedImage {
                        ZoomableImageView(image: image, zoomScale: $zoomScale)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    if case .failed(let message) = viewModel.state {
                        VStack {
                            Spacer()
                            ErrorBanner(
                                title: "推理失败",
                                message: message,
                                actionTitle: "重试",
                                action: { Task { await viewModel.startInference() } }
                            )
                            .padding(.horizontal, DesignTokens.pageMargin)
                            .padding(.bottom, DesignTokens.spacingMD)
                        }
                    }
                    
                case .inferring:
                    if let image = viewModel.selectedImage {
                        Image(uiImage: image)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .opacity(0.5)
                            .blur(radius: 1)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                    
                    VStack {
                        Spacer()
                        VStack(spacing: 8) {
                            HStack {
                                if let progress = viewModel.inferenceProgress {
                                    if progress.totalTiles > 1 {
                                        Text("处理中 \(progress.currentTile)/\(progress.totalTiles) 块")
                                            .font(.system(size: 13, weight: .medium))
                                    } else {
                                        Text(viewModel.isFastMode ? "正在极速处理..." : "正在处理...")
                                            .font(.system(size: 13, weight: .medium))
                                    }
                                } else {
                                    Text("加载模型...")
                                        .font(.system(size: 13, weight: .medium))
                                }
                                
                                Spacer()
                                
                                if let progress = viewModel.inferenceProgress {
                                    Text("\(Int(progress.fraction * 100))%")
                                        .font(.system(size: 13, weight: .bold))
                                        .foregroundColor(.green)
                                }
                            }
                            .foregroundColor(.white)
                            
                            GeometryReader { barGeo in
                                ZStack(alignment: .leading) {
                                    Capsule()
                                        .fill(Color.white.opacity(0.3))
                                        .frame(height: 6)
                                    
                                    Capsule()
                                        .fill(Color.green)
                                        .frame(width: max(barGeo.size.width * (viewModel.inferenceProgress?.fraction ?? 0.02), 6), height: 6)
                                        .animation(.easeInOut(duration: 0.3), value: viewModel.inferenceProgress?.fraction ?? 0)
                                }
                            }
                            .frame(height: 6)
                        }
                        .padding(.horizontal, 20)
                        .padding(.vertical, 16)
                        .background(Color.black.opacity(0.65))
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 24)
                        .padding(.bottom, 20)
                    }
                    
                case .completed:
                    if let original = viewModel.selectedImage,
                       let result = viewModel.resultImage {
                        ComparisonView(
                            originalImage: original,
                            resultImage: result,
                            mode: $viewModel.compareMode,
                            sliderPosition: $sliderPosition,
                            isShowingOriginal: $isShowingOriginal,
                            zoomScale: $zoomScale
                        )
                        .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - 对比控件
    private var compareControls: some View {
        HStack {
            SegmentedControl(
                selection: $viewModel.compareMode,
                items: CompareMode.allCases.map { ($0, $0.rawValue, "") }
            )
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 模型信息与极速开关
    private var modelInfoSection: some View {
        VStack(spacing: 8) {
            Button(action: { viewModel.showModelPicker = true }) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("模型")
                            .font(.caption)
                            .foregroundColor(AppTheme.tertiaryText)
                        Text(availableModels.first(where: { $0.id == viewModel.selectedModelID })?.name ?? "加载中…")
                            .font(.body)
                            .fontWeight(.medium)
                    }
                    Spacer()
                    Image(systemName: "chevron.down")
                        .foregroundColor(AppTheme.secondaryText)
                        .font(.system(size: 12, weight: .medium))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            
            if !viewModel.inputSizeText.isEmpty {
                HStack {
                    Text("尺寸：\(viewModel.inputSizeText)")
                    if !viewModel.outputSizeText.isEmpty {
                        Text("→ \(viewModel.outputSizeText)")
                    }
                    Spacer()
                }
                .font(.subheadline)
                .foregroundColor(AppTheme.tertiaryText)
            }
            
            // ⭐️ 解析 inputSizeText 计算是否大图
            let components = viewModel.inputSizeText.components(separatedBy: "×")
            let width = Int(components.first ?? "0") ?? 0
            let height = Int(components.last ?? "0") ?? 0
            let isLargeImage = (width * height) > 4000000 // 大于 400 万像素禁用
            
            // 双向绑定 ViewModel 中的 isFastMode
            Toggle(isOn: $viewModel.isFastMode) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("极速模式")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(isLargeImage ? AppTheme.tertiaryText : AppTheme.primaryText)
                    
                    Text(isLargeImage ? "当前图片过大，已禁用极速模式" : "跳过分块直接拉伸，速度快但可能失真")
                        .font(.caption)
                        .foregroundColor(isLargeImage ? .red.opacity(0.8) : AppTheme.tertiaryText)
                }
            }
            .toggleStyle(SwitchToggleStyle(tint: AppTheme.accent))
            .disabled(isLargeImage)
            .padding(.top, 4)
        }
        .padding(.horizontal, DesignTokens.pageMargin)
        .padding(.vertical, DesignTokens.spacingXS)
    }
    
    // MARK: - 底部操作
    @ViewBuilder
    private var bottomActions: some View {
        switch viewModel.state {
        case .empty:
            EmptyView()
        case .imageSelected, .failed:
            PrimaryButton(title: "开始超分", icon: "wand.and.stars", action: {
                Task { await viewModel.startInference() }
            })
        case .inferring:
            PrimaryButton(title: "取消", isDestructive: true, action: {
                viewModel.cancelInference()
            })
        case .completed:
            PrimaryButton(title: "重新超分", icon: "arrow.clockwise", action: {
                Task { await viewModel.startInference() }
            })
        }
    }
    
    // MARK: - 模型选择 Sheet
    private var modelPickerSheet: some View {
        NavigationStack {
            List {
                Section("内置模型") {
                    ForEach(availableModels.filter { $0.isBuiltin }) { model in
                        modelRow(model)
                    }
                }
                
                Section("已下载模型") {
                    let downloadedModels = availableModels.filter { !$0.isBuiltin && $0.status == .downloaded }
                    
                    if downloadedModels.isEmpty {
                        Text("暂无已下载模型")
                            .font(.subheadline)
                            .foregroundColor(AppTheme.tertiaryText)
                    } else {
                        ForEach(downloadedModels) { model in
                            modelRow(model)
                        }
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { viewModel.showModelPicker = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
    
    private func modelRow(_ model: ModelRuntimeInfo) -> some View {
        Button(action: { viewModel.selectModel(model.id) }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(.body)
                        .fontWeight(.medium)
                    Text(model.formattedSize)
                        .font(.caption)
                        .foregroundColor(AppTheme.tertiaryText)
                }
                Spacer()
                if model.id == viewModel.selectedModelID {
                    Image(systemName: "checkmark")
                        .foregroundColor(AppTheme.accent)
                }
            }
        }
        .foregroundColor(AppTheme.primaryText)
    }
}