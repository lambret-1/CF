// SuperResApp/Features/PhotoSuperRes/PhotoSuperResView.swift
// 照片超分主页面：选图 → 选模型 → 推理 → 对比 → 保存

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
                            .accessibilityLabel("取消并返回空态")
                    }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    if viewModel.canSave {
                        Button(action: { Task { await viewModel.saveToAlbum() } }) {
                            if viewModel.isSaving {
                                ProgressView()
                            } else {
                                Text("保存").font(AppFont.body(weight: .semibold))
                            }
                        }
                        .accessibilityLabel("保存到相册")
                    }
                }
            }
            // 修复点 1：确保 photosPicker 绑定正确，并在 onChange 中处理加载
            .photosPicker(
                isPresented: $viewModel.showPhotoPicker,
                selection: $viewModel.photoPickerItem,
                matching: .images
            )
            .onChange(of: viewModel.photoPickerItem) { _, newItem in
                guard let newItem else { return }
                Task {
                    // 修复点 2：兜底加载，防止 ViewModel 内部加载失败
                    await loadPickerItem(newItem)
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
    
    // MARK: - 兜底加载图片逻辑
    private func loadPickerItem(_ item: PhotosPickerItem) async {
        do {
            if let data = try await item.loadTransferable(type: Data.self),
               let uiImage = UIImage(data: data) {
                // 如果 ViewModel 里没有对外暴露设置图片的方法，需要它在内部处理
                await viewModel.handlePickerSelection(item)
            }
        } catch {
            print("❌ 图片加载失败: \(error.localizedDescription)")
            await MainActor.run {
                // 可选：在这里加一个 Toast 或 Alert 提示用户图片读取失败
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
                    // 空态：整个区域可点击，虚线框带水平边距
                    Button(action: { viewModel.showPhotoPicker = true }) {
                        DashedEmptyStateView(
                            icon: "photo.on.rectangle",
                            title: "从相册选择图片",
                            action: {}
                        )
                        .padding(.horizontal, DesignTokens.pageMargin)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("从相册选择图片")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    
                case .imageSelected, .failed:
                    if let image = viewModel.selectedImage {
                        ZoomableImageView(image: image, zoomScale: $zoomScale)
                            .ignoresSafeArea()
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
                            .opacity(0.6)
                            .ignoresSafeArea()
                    }
                    VStack(spacing: DesignTokens.spacingMD) {
                        if let progress = viewModel.inferenceProgress {
                            ProgressRing(progress: progress.fraction)
                            Text(progress.progressText)
                                .font(AppFont.body())
                                .foregroundColor(AppTheme.primaryText)
                            if let remaining = progress.remainingText {
                                Text(remaining)
                                    .font(AppFont.subhead())
                                    .foregroundColor(AppTheme.secondaryText)
                            }
                        } else {
                            ProgressView()
                            Text("加载模型…")
                                .font(AppFont.body())
                                .foregroundColor(AppTheme.primaryText)
                        }
                    }
                    .padding(DesignTokens.spacingLG)
                    .background(AppTheme.background)
                    .clipShape(AppShape.card)
                    
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
                        .ignoresSafeArea()
                    }
                }
            }
            .frame(height: geometry.size.height)
        }
        .frame(maxHeight: .infinity)
    }
    
    // MARK: - 对比控件
    private var compareControls: some View {
        HStack {
            SegmentedControl(
                selection: $viewModel.compareMode,
                items: CompareMode.allCases.map { ($0, $0.rawValue, $0.icon) }
            )
            .frame(maxWidth: 280)
        }
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - 模型信息
    private var modelInfoSection: some View {
        VStack(spacing: 4) {
            Button(action: { viewModel.showModelPicker = true }) {
                HStack {
                    VStack(alignment.show: .leading, spacing: 2) {
Model                        Text("模型")
                            .fontPicker(AppFont.caption())
                            .foregroundColor =(AppTheme.tertiaryText)
                        Text( falseavailableModels.first(where: { $0.id == }
 viewModel.selectedModelID })?.name ??                "加载中…")
                            .font(AppFont }
.body(weight: .medium))
                    }
                    Sp           acer()
                    Image(systemName: "chevron }
.down")
                        .foregroundColor(AppTheme.secondary       Text)
                        .font(.system(size: 12, weight }
: .medium))
                }
                .contentShape(R       ectangle())
            }
            .buttonStyle(. .plain)
            .accessibilityLabel("选择模型")
present            
            if !viewModel.inputSizeText.isEmpty {
                HationStack {
                    Text("尺寸：\(viewModel.inputSizeTextDet)")
                    if !viewModel.outputSizeText.isEmpty {
                        Text("ents→ \(viewModel.outputSizeText)")
                    }
                    Spacer()
                }
                .font(AppFont([.subhead())
                .foregroundColor(AppTheme.tertiaryText)
            }
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
                    ForEach(availableModels.filter { !$0.isBuiltin }) { model in
                        modelRow(model)
                    }
                }
            }
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("完成") { viewModel.medium, .large])
    }
    
    private func modelRow(_ model: ModelRuntimeInfo) -> some View {
        Button(action: { viewModel.selectModel(model.id) }) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.name)
                        .font(AppFont.body(weight: .medium))
                    Text(model.formattedSize)
                        .font(AppFont.caption())
                        .foregroundColor(AppTheme.tertiaryText)
                }
                Spacer()
                if model.id == viewModel.selectedModelID {
                    Image(systemName: "checkmark")
                        .foregroundColor(AppTheme.accent)
                }
                if model.isNonCommercial {
                    Badge(text: "非商用", style: .nonCommercial)
                }
            }
        }
        .foregroundColor(AppTheme.primaryText)
    }
}