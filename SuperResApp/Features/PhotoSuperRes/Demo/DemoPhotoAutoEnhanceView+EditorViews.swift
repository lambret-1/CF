import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

extension DemoPhotoAutoEnhanceView {
func navigationBar(topInset: CGFloat) -> some View {
        HStack(spacing: 0) {
            Button {
                dismiss()
            } label: {
                Text("取消")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 15)
                    .padding(.vertical, 7)
                    .frame(minWidth: 88, minHeight: 44)
                    .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("取消编辑")

            Spacer(minLength: 12)

            Button {
                saveToPhotos()
            } label: {
                HStack(spacing: 6) {
                    if isSaving || isProcessing {
                        ProgressView()
                            .progressViewStyle(.circular)
                            .scaleEffect(0.75)
                    } else {
                        Text("完成")
                            .font(.system(size: 15, weight: .semibold))
                    }
                }
                .foregroundStyle(isCompleteEnabled ? Color.black.opacity(0.85) : Color.secondary)
                .padding(.horizontal, 16)
                .padding(.vertical, 7)
                .frame(minWidth: 88, minHeight: 44)
                .background(
                    isCompleteEnabled
                        ? Color(red: 1.0, green: 0.88, blue: 0.48)
                        : Color(uiColor: .tertiarySystemFill),
                    in: Capsule()
                )
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isSaving)
            .accessibilityLabel("完成并保存")
            .accessibilityHint(hasChanges ? "保存到照片" : "还没有修改")
        }
        .padding(.horizontal, 20)
        .frame(height: 44)
        // 顶栏整体下移到灵动岛/传感器区域下方；44pt 热区完全落在可触区。
        .padding(.top, max(topInset, 0))
        .background(Color(uiColor: .systemBackground))
        .zIndex(10)
    }

    var quickToolbar: some View {
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

    var preview: some View {
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

    func toggleOriginalPreview() {
        compareMode = compareMode == .original ? .result : .original
    }

    var parameterPanel: some View {
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
                                AppleFreeCropEditor(image: image, onCancel: { showFreeCropEditor = false }, onApply: { rect in
                                    showFreeCropEditor = false
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
                        AppleMarkupEditor(image: image, onCancel: { showMarkupEditor = false }, onSave: { drawing in
                            showMarkupEditor = false
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

    var selectedAdjustmentBinding: Binding<Double> {
        Binding(
            get: { settings[keyPath: selectedAdjustment.keyPath] },
            set: { value in
                settings[keyPath: selectedAdjustment.keyPath] = value
                selectedPreset = .custom
                // Manual controls refine the current automatic result; they do
                // not disable or erase the automatic correction stage.
                scheduleRender(debounced: true)
            }
        )
    }

    func combinedCropRect(for selection: CGRect) -> CGRect {
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

    func cropRatioTool(_ title: String, ratio: Double?) -> some View {
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

    func autoStraighten() {
        guard let image = originalImage else { return }
        let generation = photoGeneration
        let assetIdentifier = selectedAsset?.localIdentifier
        Task {
            do {
                guard let angle = try await Task.detached(priority: .userInitiated, operation: {
                    try ApplePhotoAnalysisService.horizonAngle(for: image)
                }).value else {
                    guard photoGeneration == generation,
                          selectedAsset?.localIdentifier == assetIdentifier else { return }
                    alertMessage = "Vision 未检测到可用的地平线。"
                    return
                }
                // Discard Vision results computed for a photo that is no longer being edited.
                guard photoGeneration == generation,
                      selectedAsset?.localIdentifier == assetIdentifier else { return }
                pushUndo()
                imageTransform.straightenAngle = -Double(angle)
                scheduleRender()
            } catch {
                guard photoGeneration == generation,
                      selectedAsset?.localIdentifier == assetIdentifier else { return }
                alertMessage = error.localizedDescription
            }
        }
    }

    func cropTool(_ title: String, icon: String, action: CropAction) -> some View {
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

    var editorTabBar: some View {
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

    func infoCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon).font(.system(size: 18)).foregroundStyle(accent)
            Text(title).font(.system(size: 12, weight: .semibold))
            Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading).padding(13)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 14))
    }

    func exportRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 20)
            Text(title).font(.system(size: 11, weight: .medium))
            Spacer()
            Text(value).font(.system(size: 10)).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }

    var hasChanges: Bool {
        originalImage != nil && (settings != DemoAdjustmentSettings() || autoEnhanceEnabled || selectedPreset.filterName != nil || imageTransform != .identity || markupData != nil)
    }

    /// 完成按钮只在真正保存时禁用（防重复提交）。
    /// 没有改动时按钮依然可点，点击后给出明确提示——
    /// 否则用户看到的是一个颜色正常但毫无反应的按钮。
    var isCompleteEnabled: Bool {
        originalImage != nil && !isProcessing && !isSaving
    }

    var outputSize: String {
        guard let image = editedImage ?? originalImage else { return "—" }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
    func decimal(_ value: Double) -> String { String(format: "%.2f", value) }
}
