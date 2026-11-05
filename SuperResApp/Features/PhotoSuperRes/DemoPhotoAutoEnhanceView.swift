import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

struct DemoPhotoAutoEnhanceView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedAsset: PHAsset?
    @State private var editingInput: PHContentEditingInput?
    @State private var renderSourceURL: URL?
    @State private var usesRAWResource = false
    @State private var analysisResult: ApplePhotoAnalysisResult?
    @State private var foregroundCutout: UIImage?
    @State private var isExtractingSubject = false
    @State private var isAnalyzing = false
    @State private var isLoadingRAW = false
    @State private var showMarkupEditor = false
    @State private var showFreeCropEditor = false
    @State private var markupData: Data?
    @State private var originalImage: UIImage?
    @State private var editedImage: UIImage?
    @State private var renderedCIImage: CIImage?
    @State private var settings = DemoAdjustmentSettings()
    @State private var imageTransform = DemoImageTransform.identity
    @State private var selectedPreset: DemoPhotoPreset = .original
    @State private var activeTab: EditorTab = .adjust
    @State private var compareMode: PreviewMode = .result
    @State private var autoEnhanceEnabled = false
    @State private var autoEnhanceBaseSettings: DemoAdjustmentSettings?
    @State private var autoEnhanceBasePreset: DemoPhotoPreset?
    @State private var undoStack: [DemoEditorSnapshot] = []
    @State private var redoStack: [DemoEditorSnapshot] = []
    @State private var editingSnapshot: DemoEditorSnapshot?
    @State private var renderToken = UUID()
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var showShareSheet = false
    @State private var selectedAdjustment: AdjustmentControl = .exposure
    @State private var liveActivity: Activity<PhotoEditorActivityAttributes>?
    @State private var liveActivitySessionID: String?
    @Environment(\.dismiss) private var dismiss
    @StateObject private var libraryObserver = PhotoLibraryChangeObserver.shared
    @Environment(\.scenePhase) private var scenePhase

    init(initialPickerItem: PhotosPickerItem? = nil) {
        _pickerItem = State(initialValue: initialPickerItem)
    }

    private let accent = Color(red: 0.43, green: 0.78, blue: 0.68)

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                navigationBar
                if originalImage != nil { quickToolbar }
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                if originalImage != nil {
                    parameterPanel
                    editorTabBar
                } else {
                    welcome
                        .padding(.horizontal, 20)
                        .padding(.bottom, 18)
                }
            }
            .padding(.top, max(geometry.safeAreaInsets.top, 52) + 6)
            .padding(.bottom, max(geometry.safeAreaInsets.bottom, 8))
            .frame(width: geometry.size.width, height: geometry.size.height, alignment: .top)
            .background(Color(uiColor: .systemBackground))
        }
        .toolbar(.hidden, for: .navigationBar)
        .task {
            guard let initialItem = pickerItem, originalImage == nil else { return }
            await loadPhoto(initialItem)
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .alert("照片编辑", isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = editedImage ?? originalImage {
                DemoShareSheet(items: [image])
            }
        }
        .onOpenURL { url in
            guard url.scheme == "cfphotoeditor" else { return }
            switch url.host {
            case "cancel": dismiss()
            case "complete": saveToPhotos()
            default: break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .photoEditorIslandCommand)) { _ in
            consumeIslandCommand()
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                restoreLiveActivity()
                consumeIslandCommand()
            }
        }
        .onChange(of: isCompleteEnabled) { _, enabled in
            Task { await updateLiveActivity(canComplete: enabled) }
        }
        .onAppear {
            libraryObserver.start()
        }
        .onChange(of: libraryObserver.changeCount) { _, _ in
            refreshSelectedAsset()
        }
        .onDisappear {
            libraryObserver.stop()
            cleanupTemporaryRAWResource()
            Task { await endLiveActivity() }
        }
    }

    private var navigationBar: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .font(.system(size: 15, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 15)
            .padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            Spacer()
            Button("完成") {
                saveToPhotos()
            }
            .font(.system(size: 15, weight: .semibold))
            .foregroundStyle(isCompleteEnabled ? Color.black.opacity(0.85) : Color.secondary)
            .padding(.horizontal, 16)
            .padding(.vertical, 7)
            .background(isCompleteEnabled ? Color(red: 1.0, green: 0.88, blue: 0.48) : Color(uiColor: .tertiarySystemFill), in: Capsule())
            .disabled(!isCompleteEnabled)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var quickToolbar: some View {
        HStack(spacing: 0) {
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 42, height: 38)
            }
            .disabled(undoStack.isEmpty)
            .accessibilityLabel("撤销")
            Button { redo() } label: {
                Image(systemName: "arrow.uturn.forward.circle")
                    .font(.system(size: 21, weight: .regular))
                    .frame(width: 42, height: 38)
            }
            .disabled(redoStack.isEmpty)
            .accessibilityLabel("重做")
            Spacer(minLength: 8)
            Text(activeTab.title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button { toggleOriginalPreview() } label: {
                Image(systemName: compareMode == .original ? "eye" : "eye.slash")
                    .font(.system(size: 21))
                    .frame(width: 42, height: 38)
            }
            .accessibilityLabel("原图与效果图切换")
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 20))
                    .frame(width: 40, height: 38)
            }
            .accessibilityLabel("更换照片")
            Menu {
                Button("切换原图预览", systemImage: "eye") { toggleOriginalPreview() }
                Button("显示效果", systemImage: "eye.slash") {
                    compareMode = .result
                }
                Button("重置本次调整", systemImage: "arrow.counterclockwise") { resetEdits() }
                if selectedAsset != nil, editingInput?.adjustmentData != nil {
                    Button("恢复照片原始版本", systemImage: "arrow.uturn.backward", role: .destructive) {
                        revertPhotoToOriginal()
                    }
                }
                Button("分享照片", systemImage: "square.and.arrow.up") { showShareSheet = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 21))
                    .frame(width: 38, height: 38)
            }
            .accessibilityLabel("更多操作")
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
        .padding(.horizontal, 14)
        .padding(.bottom, 5)
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .systemBackground)
                if let originalImage {
                    let displayImage = compareMode == .original ? originalImage : (editedImage ?? originalImage)
                    Image(uiImage: displayImage)
                        .resizable()
                        .allowedDynamicRange(.high)
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .contentShape(Rectangle())
                        .onTapGesture { toggleOriginalPreview() }
                    if isProcessing {
                        VStack {
                            Spacer()
                            ProgressView()
                                .padding(12)
                                .background(.ultraThinMaterial, in: Circle())
                            Spacer().frame(height: 12)
                        }
                    }
                } else {
                    ProgressView("正在打开照片…")
                        .font(.system(size: 14))
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .clipped()
    }

    private func toggleOriginalPreview() {
        compareMode = compareMode == .original ? .result : .original
    }

    private var parameterPanel: some View {
        VStack(spacing: 6) {
            if activeTab == .adjust {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 0) {
                    ForEach(AdjustmentControl.allCases) { control in
                        Button {
                            if control == .auto { applyAutoEnhance() }
                            else { selectedAdjustment = control }
                        } label: {
                            VStack(spacing: 4) {
                                Image(systemName: control.icon)
                                    .font(.system(size: 19, weight: .regular))
                                    .frame(width: 48, height: 48)
                                    .background((control == .auto ? autoEnhanceEnabled : selectedAdjustment == control) ? Color(uiColor: .tertiarySystemFill) : .clear, in: Circle())
                                    .overlay(Circle().stroke(Color(uiColor: .systemGray4), lineWidth: (control == .auto ? autoEnhanceEnabled : selectedAdjustment == control) ? 0 : 1))
                                Text(control.title)
                                    .font(.system(size: 12, weight: (control == .auto ? autoEnhanceEnabled : selectedAdjustment == control) ? .semibold : .regular))
                                    .foregroundStyle(.primary)
                            }
                            .frame(width: 62)
                        }
                        .buttonStyle(.plain)
                    }
                    .padding(.horizontal, 10)
                    }
                }
                .frame(height: 70)
                TickMarkSlider(value: selectedAdjustmentBinding, range: selectedAdjustment.range) { editing in
                    if editing {
                        editingSnapshot = captureSnapshot()
                    } else if let snapshot = editingSnapshot {
                        let current = captureSnapshot()
                        if snapshot != current {
                            undoStack.append(snapshot)
                            if undoStack.count > 40 { undoStack.removeFirst() }
                            redoStack.removeAll()
                        }
                        editingSnapshot = nil
                    }
                }
                    .frame(height: 38)
                    .padding(.horizontal, 22)
                Text(selectedAdjustment.title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(height: 16)
            } else if activeTab == .filters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 15) {
                        ForEach(DemoPhotoPreset.allCases.filter { $0 != .custom }) { preset in
                            Button { applyPreset(preset) } label: {
                                VStack(spacing: 5) {
                                    Circle()
                                        .fill(preset.tint.opacity(0.18))
                                        .frame(width: 54, height: 54)
                                        .overlay(Image(systemName: preset.icon).font(.system(size: 20)).foregroundStyle(.primary))
                                        .overlay(Circle().stroke(selectedPreset == preset ? Color.primary : Color(uiColor: .systemGray4), lineWidth: selectedPreset == preset ? 2.5 : 1.5))
                                    Text(preset.title).font(.system(size: 11, weight: .medium)).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .frame(height: 82)
            } else if activeTab == .crop {
                VStack(spacing: 9) {
                    HStack(spacing: 18) {
                        cropTool("还原", icon: "crop", action: .reset)
                        cropTool("旋转", icon: "rotate.right", action: .rotate)
                        cropTool("翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: .flip)
                        Button {
                            showFreeCropEditor = true
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "crop.rotate").font(.system(size: 22))
                                Text("自由裁剪").font(.system(size: 10))
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $showFreeCropEditor) {
                            if let image = editedImage ?? originalImage {
                                AppleFreeCropEditor(image: image, onCancel: {}, onApply: { rect in
                                    pushUndo()
                                    imageTransform.cropRect = combinedCropRect(for: rect)
                                    imageTransform.cropAspectRatio = nil
                                    imageTransform.usesSquareCrop = false
                                    scheduleRender()
                                })
                            }
                        }
                        cropTool(imageTransform.usesPerspectiveCorrection ? "取消透视" : "透视", icon: "perspective", action: .perspective)
                        Button {
                            autoStraighten()
                        } label: {
                            VStack(spacing: 6) {
                                Image(systemName: "level").font(.system(size: 22))
                                Text("自动拉直").font(.system(size: 10))
                            }
                            .foregroundStyle(.primary)
                        }
                        .buttonStyle(.plain)
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 18) {
                            cropRatioTool("原比例", ratio: nil)
                            cropRatioTool("1:1", ratio: 1)
                            cropRatioTool("4:5", ratio: 0.8)
                            cropRatioTool("3:4", ratio: 0.75)
                            cropRatioTool("4:3", ratio: 4.0 / 3.0)
                            cropRatioTool("16:9", ratio: 16.0 / 9.0)
                        }
                        .padding(.horizontal, 14)
                    }
                }
                .frame(height: 112)
            } else if activeTab == .analysis {
                VStack(spacing: 8) {
                    HStack(spacing: 18) {
                        Button {
                            analyzeCurrentPhoto()
                        } label: {
                            Label(isAnalyzing ? "正在分析…" : "Apple Vision 分析", systemImage: "viewfinder")
                                .font(.system(size: 12, weight: .semibold))
                        }
                        .disabled(isAnalyzing)
                        if hasRAWResource {
                            Button {
                                loadRAWOriginal()
                            } label: {
                                Label(isLoadingRAW ? "载入中…" : "RAW 原片", systemImage: "camera.raw")
                                    .font(.system(size: 12, weight: .semibold))
                            }
                            .disabled(isLoadingRAW)
                        }
                    }
                    if let result = analysisResult {
                        Button {
                            extractForegroundSubject()
                        } label: {
                            Label(isExtractingSubject ? "分离中…" : "主体抠图", systemImage: "person.crop.rectangle")
                                .font(.system(size: 11, weight: .semibold))
                        }
                        .disabled(isExtractingSubject)
                        if result.depthData != nil {
                            Button {
                                pushUndo()
                                imageTransform.usesDepthBlur.toggle()
                                scheduleRender()
                            } label: {
                                Label(imageTransform.usesDepthBlur ? "关闭景深" : "Apple 景深效果", systemImage: "camera.aperture")
                                    .font(.system(size: 11, weight: .semibold))
                            }
                        }
                        if let foregroundCutout {
                            Image(uiImage: foregroundCutout)
                                .resizable()
                                .scaledToFit()
                                .frame(height: 56)
                                .contextMenu {
                                    Button("分享透明主体", systemImage: "square.and.arrow.up") {
                                        editedImage = foregroundCutout
                                        showShareSheet = true
                                    }
                                }
                        }
                        if !result.semanticMatteTypes.isEmpty {
                            Text("Apple 语义蒙版：\(result.semanticMatteTypes.joined(separator: "、"))")
                                .font(.system(size: 10))
                                .foregroundStyle(.secondary)
                        }
                        HStack(spacing: 14) {
                            analysisMetric("人脸", value: "\(result.faceCount)")
                            analysisMetric("主体", value: "\(result.foregroundInstanceCount)")
                            analysisMetric("景深", value: result.depthData == nil ? "无" : "有")
                            analysisMetric("水平", value: result.horizonAngle.map { String(format: "%.1f°", $0 * 180 / .pi) } ?? "—")
                        }
                    } else {
                        Text("检测人脸、主体分割、地平线和可用景深数据")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                }
                .frame(height: 92)
            } else if activeTab == .livePhoto {
                if let asset = selectedAsset, asset.mediaSubtypes.contains(.photoLive) {
                    AppleLivePhotoPreview(asset: asset)
                        .frame(height: 110)
                } else {
                    Text("当前照片不是 Live Photo")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .frame(height: 92)
                }
            } else if activeTab == .markup {
                Button {
                    showMarkupEditor = true
                } label: {
                    Label("打开 Apple Pencil 标注", systemImage: "pencil.tip.crop.circle")
                        .font(.system(size: 13, weight: .semibold))
                }
                .frame(height: 92)
                .sheet(isPresented: $showMarkupEditor) {
                    if let image = editedImage ?? originalImage {
                        AppleMarkupEditor(image: image, onCancel: {}, onSave: { drawing in
                            pushUndo()
                            markupData = drawing.dataRepresentation()
                            scheduleRender()
                        })
                    }
                }
            }
        }
        .padding(.top, 8)
        .padding(.bottom, 2)
    }

    private var selectedAdjustmentBinding: Binding<Double> {
        Binding(
            get: { settings[keyPath: selectedAdjustment.keyPath] },
            set: { value in
                settings[keyPath: selectedAdjustment.keyPath] = value
                selectedPreset = .custom
                autoEnhanceEnabled = false
                autoEnhanceBaseSettings = nil
                autoEnhanceBasePreset = nil
                scheduleRender(debounced: true)
            }
        )
    }

    private func combinedCropRect(for selection: CGRect) -> CGRect {
        let base: CGRect
        if let existing = imageTransform.cropRect {
            base = existing
        } else if let ratio = imageTransform.cropAspectRatio ?? (imageTransform.usesSquareCrop ? 1 : nil),
                  let image = originalImage {
            var sourceAspect = image.size.width / max(image.size.height, 1)
            if abs(imageTransform.quarterTurnsClockwise % 2) == 1 {
                sourceAspect = 1 / max(sourceAspect, 0.0001)
            }
            if sourceAspect > ratio {
                let width = ratio / sourceAspect
                base = CGRect(x: (1 - width) / 2, y: 0, width: width, height: 1)
            } else {
                let height = sourceAspect / ratio
                base = CGRect(x: 0, y: (1 - height) / 2, width: 1, height: height)
            }
        } else {
            base = CGRect(x: 0, y: 0, width: 1, height: 1)
        }
        return CGRect(
            x: base.minX + selection.minX * base.width,
            y: base.minY + selection.minY * base.height,
            width: selection.width * base.width,
            height: selection.height * base.height
        )
    }

    private func cropRatioTool(_ title: String, ratio: Double?) -> some View {
        Button {
            var next = imageTransform
            next.cropAspectRatio = ratio
            next.cropRect = nil
            next.usesSquareCrop = false
            guard next != imageTransform else { return }
            pushUndo()
            imageTransform = next
            scheduleRender()
        } label: {
            let isSelected = ratio == nil
                ? imageTransform.cropRect == nil && imageTransform.cropAspectRatio == nil && !imageTransform.usesSquareCrop
                : imageTransform.cropAspectRatio == ratio
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(isSelected ? .primary : .secondary)
                .padding(.horizontal, 9)
                .padding(.vertical, 6)
                .background(
                    isSelected ? Color(uiColor: .tertiarySystemFill) : .clear,
                    in: Capsule()
                )
        }
        .buttonStyle(.plain)
    }

    private func autoStraighten() {
        guard let image = originalImage else { return }
        Task {
            do {
                guard let angle = try await Task.detached(priority: .userInitiated, operation: {
                    try ApplePhotoAnalysisService.horizonAngle(for: image)
                }).value else {
                    alertMessage = "Vision 未检测到可用的地平线。"
                    return
                }
                pushUndo()
                imageTransform.straightenAngle = -Double(angle)
                scheduleRender()
            } catch {
                alertMessage = error.localizedDescription
            }
        }
    }

    private func cropTool(_ title: String, icon: String, action: CropAction) -> some View {
        Button {
            var next = imageTransform
            switch action {
            case .reset: next = .identity
            case .rotate: next.quarterTurnsClockwise = (next.quarterTurnsClockwise + 1) % 4
            case .flip: next.isHorizontallyFlipped.toggle()
            case .toggleSquare: next.usesSquareCrop.toggle()
            case .perspective: next.usesPerspectiveCorrection.toggle()
            }
            guard next != imageTransform else { return }
            pushUndo()
            imageTransform = next
            scheduleRender()
        } label: {
            VStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 22))
                Text(title).font(.system(size: 10))
            }
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }

    private var editorTabBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                ForEach(EditorTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 20, weight: activeTab == tab ? .semibold : .regular))
                                .frame(height: 23)
                            Text(tab.title)
                                .font(.system(size: 10, weight: activeTab == tab ? .semibold : .regular))
                        }
                        .foregroundStyle(activeTab == tab ? .primary : Color(uiColor: .tertiaryLabel))
                        .frame(minWidth: 72)
                        .padding(.top, 7)
                        .padding(.bottom, 5)
                        .overlay(alignment: .top) {
                            if activeTab == tab {
                                Capsule().fill(Color(red: 1.0, green: 0.72, blue: 0.12)).frame(width: 7, height: 7).offset(y: -1)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 12)
        }
        .padding(.bottom, 4)
        .background(Color(uiColor: .systemBackground))
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始编辑").font(.system(size: 18, weight: .bold))
                    Text("选择一张照片，解锁完整编辑工具")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "wand.and.stars").font(.system(size: 25)).foregroundStyle(accent)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("从相册导入照片", systemImage: "plus")
                    .font(.system(size: 14, weight: .semibold))
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black.opacity(0.85))
            }
            HStack(spacing: 7) {
                featurePill("原生增强", icon: "sparkles")
                featurePill("精细调节", icon: "slider.horizontal.3")
                featurePill("高清导出", icon: "square.and.arrow.down")
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private func featurePill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    private func infoCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(accent)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    private func exportRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 20)
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }

    private var hasChanges: Bool {
        originalImage != nil && (settings != DemoAdjustmentSettings() || autoEnhanceEnabled || selectedPreset.filterName != nil || imageTransform != .identity || markupData != nil)
    }

    private var isCompleteEnabled: Bool {
        hasChanges && !isProcessing && !isSaving
    }

    private var outputSize: String {
        guard let image = editedImage ?? originalImage else { return "—" }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    private func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
    private func decimal(_ value: Double) -> String { String(format: "%.2f", value) }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            var loadedImage: UIImage?
            var loadedAsset: PHAsset?
            var loadedInput: PHContentEditingInput?
            var loadedSourceURL: URL?
            var loadedUsesRAW = false

            if let identifier = item.itemIdentifier {
                do {
                    let asset = try await PhotoKitEditingService.shared.fetchAsset(localIdentifier: identifier)
                    let input = try await PhotoKitEditingService.shared.requestEditingInput(for: asset)
                    let isNativeRAW = input.uniformTypeIdentifier.flatMap { UTType($0) }?.conforms(to: .rawImage) == true
                    let shouldUseRAW = isNativeRAW || adjustmentDataUsesRAW(input.adjustmentData)
                    if shouldUseRAW && !isNativeRAW {
                        do {
                            let rawURL = try await PhotoKitEditingService.shared.rawResourceURL(for: asset)
                            loadedImage = try await Task.detached(priority: .userInitiated) {
                                try ApplePhotoAnalysisService.renderRawImage(at: rawURL)
                            }.value
                            loadedSourceURL = rawURL
                            loadedUsesRAW = true
                        } catch {
                            loadedImage = try await PhotoKitEditingService.shared.originalImage(from: input)
                            loadedSourceURL = input.fullSizeImageURL
                            loadedUsesRAW = false
                        }
                    } else {
                        loadedImage = try await PhotoKitEditingService.shared.originalImage(from: input)
                        loadedSourceURL = input.fullSizeImageURL
                        loadedUsesRAW = isNativeRAW
                    }
                    loadedAsset = asset
                    loadedInput = input
                } catch {
                    // Keep the system picker import path available when the asset is outside
                    // the app's current PhotoKit authorization scope.
                }
            }

            if loadedImage == nil,
               let data = try await item.loadTransferable(type: Data.self) {
                loadedImage = UIImage(data: data)
            }
            guard let image = loadedImage else {
                alertMessage = "无法读取所选照片，请重新选择。"
                return
            }

            pickerItem = nil
            cleanupTemporaryRAWResource()
            renderToken = UUID()
            selectedAsset = loadedAsset
            editingInput = loadedInput
            renderSourceURL = loadedSourceURL
            usesRAWResource = loadedUsesRAW
            originalImage = image
            editedImage = image
            settings = DemoAdjustmentSettings()
            imageTransform = .identity
            selectedPreset = .original
            autoEnhanceBaseSettings = nil
            autoEnhanceBasePreset = nil
            autoEnhanceEnabled = false
            undoStack.removeAll()
            redoStack.removeAll()
            compareMode = .result
            analysisResult = nil
            foregroundCutout = nil
            markupData = nil
            restoreAdjustmentData(loadedInput?.adjustmentData)
            scheduleRender()
            await startLiveActivity()
        } catch {
            alertMessage = "读取照片失败：\(error.localizedDescription)"
        }
    }


    @MainActor
    private func startLiveActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<PhotoEditorActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        liveActivity = nil
        let sessionID = UUID().uuidString
        liveActivitySessionID = sessionID
        let attributes = PhotoEditorActivityAttributes(sessionID: sessionID)
        let state = PhotoEditorActivityAttributes.ContentState(
            status: "未修改",
            selectedAction: "edit",
            canComplete: false
        )
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)),
                pushType: nil
            )
        } catch {
            liveActivity = nil
            liveActivitySessionID = nil
            alertMessage = "无法启动灵动岛活动：\(error.localizedDescription)"
        }
    }

    @MainActor
    private func restoreLiveActivity() {
        guard let activity = Activity<PhotoEditorActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == liveActivitySessionID
        }) ?? Activity<PhotoEditorActivityAttributes>.activities.first else { return }
        liveActivity = activity
        liveActivitySessionID = activity.attributes.sessionID
        Task { await updateLiveActivity(canComplete: isCompleteEnabled) }
    }

    @MainActor
    private func updateLiveActivity(canComplete: Bool) async {
        guard let liveActivity else { return }
        let state = PhotoEditorActivityAttributes.ContentState(
            status: canComplete ? "已修改" : "未修改",
            selectedAction: "edit",
            canComplete: canComplete
        )
        await liveActivity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        )
    }

    @MainActor
    private func endLiveActivity() async {
        guard let liveActivity else { return }
        await liveActivity.end(nil, dismissalPolicy: .immediate)
        self.liveActivity = nil
        liveActivitySessionID = nil
    }

    private func consumeIslandCommand() {
        guard let defaults = UserDefaults(suiteName: PhotoEditorActivityAttributes.appGroupID),
              let command = defaults.string(forKey: PhotoEditorActivityAttributes.commandKey),
              let sessionID = defaults.string(forKey: PhotoEditorActivityAttributes.sessionKey),
              sessionID == liveActivitySessionID else { return }
        defaults.removeObject(forKey: PhotoEditorActivityAttributes.commandKey)
        defaults.removeObject(forKey: PhotoEditorActivityAttributes.sessionKey)
        switch command {
        case "cancel":
            dismiss()
        case "complete":
            saveToPhotos()
        default:
            break
        }
    }

    private func applyAutoEnhance() {
        guard originalImage != nil else { return }
        pushUndo()
        if autoEnhanceEnabled {
            settings = autoEnhanceBaseSettings ?? DemoAdjustmentSettings()
            selectedPreset = autoEnhanceBasePreset ?? .original
            autoEnhanceBaseSettings = nil
            autoEnhanceBasePreset = nil
            autoEnhanceEnabled = false
        } else {
            autoEnhanceBaseSettings = settings
            autoEnhanceBasePreset = selectedPreset
            autoEnhanceEnabled = true
            selectedPreset = .custom
        }
        scheduleRender()
    }

    private func applyPreset(_ preset: DemoPhotoPreset) {
        let next = DemoEditorSnapshot(
            settings: preset.settings,
            selectedPreset: preset,
            autoEnhanceEnabled: false,
            autoEnhanceBaseSettings: nil,
            autoEnhanceBasePreset: nil,
            imageTransform: imageTransform,
            markupData: markupData
        )
        guard next != captureSnapshot() else { return }
        pushUndo()
        restoreSnapshot(next)
    }

    private func captureSnapshot() -> DemoEditorSnapshot {
        DemoEditorSnapshot(
            settings: settings,
            selectedPreset: selectedPreset,
            autoEnhanceEnabled: autoEnhanceEnabled,
            autoEnhanceBaseSettings: autoEnhanceBaseSettings,
            autoEnhanceBasePreset: autoEnhanceBasePreset,
            imageTransform: imageTransform,
            markupData: markupData
        )
    }

    private func restoreSnapshot(_ snapshot: DemoEditorSnapshot) {
        settings = snapshot.settings
        selectedPreset = snapshot.selectedPreset
        autoEnhanceEnabled = snapshot.autoEnhanceEnabled
        autoEnhanceBaseSettings = snapshot.autoEnhanceBaseSettings
        autoEnhanceBasePreset = snapshot.autoEnhanceBasePreset
        imageTransform = snapshot.imageTransform
        markupData = snapshot.markupData
        scheduleRender()
    }

    private func pushUndo() {
        let snapshot = captureSnapshot()
        if undoStack.last != snapshot {
            undoStack.append(snapshot)
            if undoStack.count > 40 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(captureSnapshot())
        restoreSnapshot(previous)
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(captureSnapshot())
        restoreSnapshot(next)
    }

    private func resetEdits() {
        let next = DemoEditorSnapshot(
            settings: DemoAdjustmentSettings(),
            selectedPreset: .original,
            autoEnhanceEnabled: false,
            autoEnhanceBaseSettings: nil,
            autoEnhanceBasePreset: nil,
            imageTransform: .identity,
            markupData: nil
        )
        guard next != captureSnapshot() else { return }
        pushUndo()
        restoreSnapshot(next)
        compareMode = .result
    }

    private func scheduleRender(debounced: Bool = false) {
        guard let originalImage else { return }
        let token = UUID()
        renderToken = token
        isProcessing = true
        let currentSettings = settings
        let useAutoEnhance = autoEnhanceEnabled
        let currentFilterName = selectedPreset.filterName
        let currentTransform = imageTransform
        let currentMarkupData = markupData
        let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL

        Task {
            if debounced { try? await Task.sleep(for: .milliseconds(100)) }
            guard renderToken == token else { return }
            let result = await Task.detached(priority: .userInitiated) {
                DemoImageProcessor.renderCIImage(
                    originalImage,
                    settings: currentSettings,
                    autoEnhance: useAutoEnhance,
                    filterName: currentFilterName,
                    transform: currentTransform,
                    sourceURL: sourceURL,
                    markupData: currentMarkupData
                )
            }.value
            guard renderToken == token else { return }

            if let result {
                renderedCIImage = result
                let preview = DemoImageProcessor.makePreviewImage(from: result, scale: originalImage.scale) ?? originalImage
                editedImage = preview
            } else {
                renderedCIImage = nil
                editedImage = originalImage
            }
            isProcessing = false
        }
    }

    private func adjustmentDataUsesRAW(_ adjustmentData: PHAdjustmentData?) -> Bool {
        guard let adjustmentData,
              let root = try? JSONSerialization.jsonObject(with: adjustmentData.data) as? [String: Any] else {
            return false
        }
        return root["usesRAW"] as? Bool ?? false
    }

    private func refreshSelectedAsset() {
        guard let identifier = selectedAsset?.localIdentifier else { return }
        Task {
            guard let refreshed = try? await PhotoKitEditingService.shared.fetchAsset(localIdentifier: identifier),
                  let refreshedInput = try? await PhotoKitEditingService.shared.requestEditingInput(for: refreshed) else {
                return
            }
            selectedAsset = refreshed
            editingInput = refreshedInput
            if !usesRAWResource {
                renderSourceURL = refreshedInput.fullSizeImageURL
            }
        }
    }

    private func restoreAdjustmentData(_ adjustmentData: PHAdjustmentData?) {
        guard let adjustmentData,
              adjustmentData.formatIdentifier == "com.superres.app.photo-editor",
              let root = try? JSONSerialization.jsonObject(with: adjustmentData.data) as? [String: Any] else {
            return
        }

        if let values = root["settings"] as? [String: Double] {
            settings.exposure = values["exposure"] ?? 0
            settings.brightness = values["brightness"] ?? 0
            settings.contrast = values["contrast"] ?? 1
            settings.saturation = values["saturation"] ?? 1
            settings.vibrance = values["vibrance"] ?? 0
            settings.highlights = values["highlights"] ?? 0
            settings.shadows = values["shadows"] ?? 0
            settings.temperature = values["temperature"] ?? 6500
            settings.tint = values["tint"] ?? 0
            settings.sharpness = values["sharpness"] ?? 0
            settings.noiseReduction = values["noiseReduction"] ?? 0
            settings.vignette = values["vignette"] ?? 0
        }
        if let rawPreset = root["preset"] as? String,
           let preset = DemoPhotoPreset(rawValue: rawPreset) {
            selectedPreset = preset
        }
        autoEnhanceEnabled = root["autoEnhance"] as? Bool ?? false
        if let transform = root["rotation"] as? Int {
            imageTransform.quarterTurnsClockwise = transform
        }
        imageTransform.isHorizontallyFlipped = root["horizontalFlip"] as? Bool ?? false
        imageTransform.usesSquareCrop = root["squareCrop"] as? Bool ?? false
        imageTransform.straightenAngle = root["straightenAngle"] as? Double ?? 0
        imageTransform.usesPerspectiveCorrection = root["perspectiveCorrection"] as? Bool ?? false
        imageTransform.usesDepthBlur = root["depthBlur"] as? Bool ?? false
        if root["usesRAW"] as? Bool == true,
           renderSourceURL?.lastPathComponent.hasPrefix("CF-RAW-") == true {
            usesRAWResource = true
        }
        let cropRatio = root["cropAspectRatio"] as? Double ?? 0
        imageTransform.cropAspectRatio = cropRatio > 0 ? cropRatio : nil
        if let crop = root["cropRect"] as? [Double], crop.count == 4 {
            imageTransform.cropRect = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
        } else {
            imageTransform.cropRect = nil
        }
        if let encodedMarkup = root["markupData"] as? String, !encodedMarkup.isEmpty {
            markupData = Data(base64Encoded: encodedMarkup)
        }
    }

    private var hasRAWResource: Bool {
        guard let selectedAsset else { return false }
        return PHAssetResource.assetResources(for: selectedAsset)
            .contains(where: ApplePhotoAnalysisService.isRawResource)
    }

    private func cleanupTemporaryRAWResource() {
        guard let url = renderSourceURL,
              url.lastPathComponent.hasPrefix("CF-RAW-") else { return }
        try? FileManager.default.removeItem(at: url)
        renderSourceURL = nil
    }

    private func loadRAWOriginal() {
        guard let asset = selectedAsset else { return }
        isLoadingRAW = true
        Task {
            do {
                let url = try await PhotoKitEditingService.shared.rawResourceURL(for: asset)
                let rawImage = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.renderRawImage(at: url)
                }.value
                cleanupTemporaryRAWResource()
                undoStack.removeAll()
                redoStack.removeAll()
                renderSourceURL = url
                usesRAWResource = true
                originalImage = rawImage
                editedImage = rawImage
                renderedCIImage = CIImage(image: rawImage)
                settings = DemoAdjustmentSettings()
                selectedPreset = .original
                autoEnhanceEnabled = false
                imageTransform = .identity
                markupData = nil
                analysisResult = nil
                compareMode = .result
                scheduleRender()
            } catch {
                alertMessage = error.localizedDescription
            }
            isLoadingRAW = false
        }
    }

    private func extractForegroundSubject() {
        guard let image = originalImage else { return }
        isExtractingSubject = true
        Task {
            do {
                let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL
                foregroundCutout = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.foregroundCutout(from: image, sourceURL: sourceURL)
                }.value
                if foregroundCutout == nil {
                    alertMessage = "Vision 未检测到可分离的前景主体。"
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            isExtractingSubject = false
        }
    }

    private func analyzeCurrentPhoto() {
        guard let image = originalImage else { return }
        isAnalyzing = true
        Task {
            do {
                let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL
                let result = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.analyze(image, sourceURL: sourceURL)
                }.value
                analysisResult = result
            } catch {
                alertMessage = error.localizedDescription
            }
            isAnalyzing = false
        }
    }

    private func analysisMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func revertPhotoToOriginal() {
        guard let asset = selectedAsset else { return }
        isSaving = true
        Task {
            do {
                try await PhotoKitEditingService.shared.revertToOriginal(asset: asset)
                let refreshedAsset = try await PhotoKitEditingService.shared.fetchAsset(localIdentifier: asset.localIdentifier)
                let refreshedInput = try await PhotoKitEditingService.shared.requestEditingInput(for: refreshedAsset)
                let image = try await PhotoKitEditingService.shared.originalImage(from: refreshedInput)
                selectedAsset = refreshedAsset
                editingInput = refreshedInput
                renderSourceURL = refreshedInput.fullSizeImageURL
                usesRAWResource = refreshedInput.uniformTypeIdentifier.flatMap { UTType($0) }?.conforms(to: .rawImage) == true
                originalImage = image
                editedImage = image
                settings = DemoAdjustmentSettings()
                selectedPreset = .original
                autoEnhanceEnabled = false
                autoEnhanceBaseSettings = nil
                autoEnhanceBasePreset = nil
                imageTransform = .identity
                markupData = nil
                undoStack.removeAll()
                redoStack.removeAll()
                analysisResult = nil
                compareMode = .result
                scheduleRender()
                alertMessage = "已通过 PhotoKit 恢复照片原始版本。"
            } catch {
                alertMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    private func saveToPhotos() {
        guard isCompleteEnabled, let image = editedImage ?? originalImage else { return }
        guard let cgImage = image.cgImage else { alertMessage = "无法读取当前图像，请重新导入照片。"; return }
        isSaving = true
        Task {
            do {
                if let asset = selectedAsset, let input = editingInput {
                    let adjustment: [String: Any] = [
                        "settings": [
                            "exposure": settings.exposure,
                            "brightness": settings.brightness,
                            "contrast": settings.contrast,
                            "saturation": settings.saturation,
                            "vibrance": settings.vibrance,
                            "highlights": settings.highlights,
                            "shadows": settings.shadows,
                            "temperature": settings.temperature,
                            "tint": settings.tint,
                            "sharpness": settings.sharpness,
                            "noiseReduction": settings.noiseReduction,
                            "vignette": settings.vignette
                        ],
                        "markupData": markupData?.base64EncodedString() ?? "",
                        "preset": selectedPreset.rawValue,
                        "autoEnhance": autoEnhanceEnabled,
                        "rotation": imageTransform.quarterTurnsClockwise,
                        "horizontalFlip": imageTransform.isHorizontallyFlipped,
                        "squareCrop": imageTransform.usesSquareCrop,
                        "straightenAngle": imageTransform.straightenAngle,
                        "perspectiveCorrection": imageTransform.usesPerspectiveCorrection,
                        "depthBlur": imageTransform.usesDepthBlur,
                        "usesRAW": usesRAWResource,
                        "cropAspectRatio": imageTransform.cropAspectRatio ?? 0,
                        "cropRect": imageTransform.cropRect.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] } ?? []
                    ]
                    let data = try JSONSerialization.data(withJSONObject: adjustment, options: [.sortedKeys])
                    if asset.mediaSubtypes.contains(.photoLive), input.livePhoto != nil {
                        try await PhotoKitEditingService.shared.saveLivePhoto(
                            asset: asset,
                            input: input,
                            settings: settings,
                            filterName: selectedPreset.filterName,
                            autoEnhance: autoEnhanceEnabled,
                            transform: imageTransform,
                            adjustmentData: data,
                            markupData: markupData,
                            markupSize: originalImage?.size ?? image.size,
                            markupScale: originalImage?.scale ?? image.scale
                        )
                        alertMessage = "Live Photo 的照片帧与动态视频帧已作为非破坏性修改保存。"
                    } else {
                        if let renderedCIImage {
                            try await PhotoKitEditingService.shared.saveRenderedCIImage(
                                renderedCIImage,
                                asset: asset,
                                input: input,
                                adjustmentData: data,
                                isHDR: usesRAWResource || ((renderSourceURL ?? input.fullSizeImageURL).map {
                                    ApplePhotoAnalysisService.containsHDRGainMap(at: $0)
                                } ?? false)
                            )
                        } else {
                            try await PhotoKitEditingService.shared.saveRenderedImage(
                                cgImage,
                                asset: asset,
                                input: input,
                                adjustmentData: data
                            )
                        }
                        alertMessage = "已将编辑作为 10-bit HEIF 非破坏性修改保存到原照片。"
                    }
                } else {
                    try await PhotoLibraryService.shared.save(cgImage)
                    alertMessage = "照片已另存到系统相册。"
                }
                await endLiveActivity()
            } catch {
                alertMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private struct DemoEditorSnapshot: Equatable {
    let settings: DemoAdjustmentSettings
    let selectedPreset: DemoPhotoPreset
    let autoEnhanceEnabled: Bool
    let autoEnhanceBaseSettings: DemoAdjustmentSettings?
    let autoEnhanceBasePreset: DemoPhotoPreset?
    let imageTransform: DemoImageTransform
    let markupData: Data?
}

private enum CropAction { case reset, rotate, flip, toggleSquare, perspective }

private enum PreviewMode { case result, original }

private enum EditorTab: String, CaseIterable, Identifiable {
    case adjust, filters, crop, analysis, livePhoto, markup
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adjust: "调整"
        case .filters: "滤镜"
        case .crop: "裁剪"
        case .analysis: "识别"
        case .livePhoto: "实况"
        case .markup: "标注"
        }
    }
    var icon: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .filters: "camera.filters"
        case .crop: "crop"
        case .analysis: "viewfinder"
        case .livePhoto: "livephoto"
        case .markup: "pencil.tip.crop.circle"
        }
    }
}

private enum AdjustmentControl: String, CaseIterable, Identifiable {
    case auto, exposure, contrast, saturation, vibrance, brightness, highlights, shadows, temperature, tint, sharpness, noiseReduction, vignette
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "自动"
        case .exposure: "曝光"
        case .contrast: "对比度"
        case .saturation: "饱和度"
        case .vibrance: "自然饱和度"
        case .brightness: "亮度"
        case .highlights: "高光"
        case .shadows: "阴影"
        case .temperature: "色温"
        case .tint: "色调"
        case .sharpness: "锐度"
        case .noiseReduction: "降噪"
        case .vignette: "暗角"
        }
    }
    var icon: String {
        switch self {
        case .auto: "wand.and.stars"
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop.fill"
        case .vibrance: "drop"
        case .brightness: "sun.max"
        case .highlights: "sun.max.fill"
        case .shadows: "sun.haze"
        case .temperature: "thermometer.medium"
        case .tint: "circle.lefthalf.filled"
        case .sharpness: "viewfinder"
        case .noiseReduction: "aqi.medium"
        case .vignette: "circle.dashed"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .auto: -2...2
        case .exposure: -2...2
        case .contrast: 0.5...1.8
        case .saturation: 0...2
        case .vibrance: -1...1
        case .brightness: -0.5...0.5
        case .highlights: -1...1
        case .shadows: -1...1
        case .temperature: 2500...10000
        case .tint: -150...150
        case .sharpness: 0...2
        case .noiseReduction: 0...0.1
        case .vignette: -2...2
        }
    }
    var keyPath: WritableKeyPath<DemoAdjustmentSettings, Double> {
        switch self {
        case .auto, .exposure: \.exposure
        case .contrast: \.contrast
        case .saturation: \.saturation
        case .vibrance: \.vibrance
        case .brightness: \.brightness
        case .highlights: \.highlights
        case .shadows: \.shadows
        case .temperature: \.temperature
        case .tint: \.tint
        case .sharpness: \.sharpness
        case .noiseReduction: \.noiseReduction
        case .vignette: \.vignette
        }
    }
}

private struct DemoShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}


private struct TickMarkSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    var onEditingChanged: (Bool) -> Void = { _ in }
    @State private var dragStartValue: Double?

    private var progress: CGFloat {
        guard range.upperBound > range.lowerBound else { return 0 }
        return CGFloat((value - range.lowerBound) / (range.upperBound - range.lowerBound))
    }

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width
            let tickSpacing: CGFloat = 12
            let rulerWidth = tickSpacing * 60
            ZStack {
                HStack(spacing: tickSpacing - 1) {
                    ForEach(0..<61, id: \.self) { index in
                        Rectangle()
                            .fill(Color(uiColor: .tertiaryLabel).opacity(index.isMultiple(of: 5) ? 0.72 : 0.42))
                            .frame(width: 1, height: index.isMultiple(of: 5) ? 22 : 12)
                    }
                }
                .frame(width: rulerWidth, alignment: .leading)
                .offset(x: width / 2 - progress * rulerWidth)
                .frame(maxWidth: .infinity, alignment: .leading)
                .clipped()
                Rectangle()
                    .fill(Color.primary)
                    .frame(width: 2, height: 38)
                    .position(x: width / 2, y: geometry.size.height / 2)
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        if dragStartValue == nil {
                            dragStartValue = value
                            onEditingChanged(true)
                        }
                        let start = dragStartValue ?? value
                        let delta = Double(gesture.translation.width / max(width, 1)) * (range.upperBound - range.lowerBound)
                        value = min(max(start + delta, range.lowerBound), range.upperBound)
                    }
                    .onEnded { _ in
                        dragStartValue = nil
                        onEditingChanged(false)
                    }
            )
        }
        .accessibilityElement()
        .accessibilityLabel("参数强度")
        .accessibilityValue(String(format: "%.2f", value))
        .accessibilityAdjustableAction { direction in
            let step = (range.upperBound - range.lowerBound) / 100
            onEditingChanged(true)
            switch direction {
            case .increment: value = min(value + step, range.upperBound)
            case .decrement: value = max(value - step, range.lowerBound)
            @unknown default: break
            }
            onEditingChanged(false)
        }
    }
}
