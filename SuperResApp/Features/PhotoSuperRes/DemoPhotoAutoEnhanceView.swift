import SwiftUI
import PhotosUI
import UIKit

struct DemoPhotoAutoEnhanceView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var editedImage: UIImage?
    @State private var settings = DemoAdjustmentSettings()
    @State private var selectedPreset: DemoPhotoPreset = .original
    @State private var activeTab: EditorTab = .enhance
    @State private var compareMode: PreviewMode = .result
    @State private var comparePosition: CGFloat = 0.5
    @State private var autoEnhanceEnabled = false
    @State private var undoStack: [DemoEditSnapshot] = []
    @State private var redoStack: [DemoEditSnapshot] = []
    @State private var editingSnapshots: [String: DemoEditSnapshot] = [:]
    @State private var renderToken = UUID()
    @State private var showAILab = false
    @State private var isLoadingPhoto = false
    @State private var alertTitle = "照片已保存"
    @Environment(\.dismiss) private var dismiss
    @State private var isProcessing = false
    @State private var isRenderPending = false
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var showShareSheet = false

    private let accent = DemoPhotoStudioTheme.accent
    private static let presets: [DemoPhotoPreset] = [.original, .portrait, .landscape, .night, .food]
    private static let sliderSpecs: [DemoSliderSpec] = [
        DemoSliderSpec(title: "曝光", icon: "sun.max", keyPath: \.exposure, range: -2...2, usesSignedFormat: true),
        DemoSliderSpec(title: "亮度", icon: "sun.min", keyPath: \.brightness, range: -0.5...0.5, usesSignedFormat: true),
        DemoSliderSpec(title: "对比度", icon: "circle.lefthalf.filled", keyPath: \.contrast, range: 0.5...1.8, usesSignedFormat: false),
        DemoSliderSpec(title: "饱和度", icon: "drop", keyPath: \.saturation, range: 0...2, usesSignedFormat: false),
        DemoSliderSpec(title: "色温", icon: "thermometer.medium", keyPath: \.temperature, range: -100...100, usesSignedFormat: true),
        DemoSliderSpec(title: "高光", icon: "sun.max.fill", keyPath: \.highlights, range: -1...1, usesSignedFormat: true),
        DemoSliderSpec(title: "阴影", icon: "moon", keyPath: \.shadows, range: -1...1, usesSignedFormat: true),
        DemoSliderSpec(title: "锐度", icon: "viewfinder", keyPath: \.sharpness, range: 0...2, usesSignedFormat: false)
    ]

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    preview
                    if originalImage == nil { welcome }
                    else { editor }
                }
                .padding(.horizontal, 18)
                .padding(.top, 12)
                .padding(.bottom, 22)
            }
            if originalImage != nil { bottomBar }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .alert(alertTitle, isPresented: Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = editedImage ?? originalImage { DemoShareSheet(items: [image]) }
        }
        .sheet(isPresented: $showAILab) { NavigationStack { DemoAILabView() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { dismiss() } label: { Image(systemName: "chevron.left").font(.body.weight(.semibold)).frame(width: 44, height: 44).contentShape(Rectangle()) }
                .accessibilityLabel("返回照片功能")
            VStack(alignment: .leading, spacing: 2) {
                Text("PHOTO STUDIO")
                    .font(.caption.weight(.black))
                    .tracking(2)
                Text("智能照片编辑")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled(undoStack.isEmpty).accessibilityLabel("撤销").accessibilityHint("恢复上一步编辑")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward").frame(width: 44, height: 44).contentShape(Rectangle()) }
                .disabled(redoStack.isEmpty).accessibilityLabel("重做").accessibilityHint("重新应用已撤销的编辑")
            Menu { Button { showAILab = true } label: { Label("AI 实验室", systemImage: "sparkles") } } label: {
                Image(systemName: "ellipsis.circle").frame(width: 44, height: 44).contentShape(Rectangle())
            }.accessibilityLabel("更多功能")
            Button("重置") { resetEdits() }.font(.body.weight(.semibold)).frame(minWidth: 44, minHeight: 44).disabled(originalImage == nil)
        }
        .font(.body.weight(.medium))
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .background(.bar)
    }

    private var preview: some View {
        VStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 23, style: .continuous)
                    .fill(Color(red: 0.10, green: 0.12, blue: 0.13))
                if let originalImage {
                    DemoComparisonPreview(originalImage: originalImage, editedImage: editedImage ?? originalImage,
                        mode: compareMode, position: $comparePosition)
                        .padding(5)
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 43, weight: .light)).foregroundStyle(accent)
                        Text("让每一张照片，都值得珍藏")
                            .font(.subheadline.weight(.semibold)).foregroundStyle(.white)
                        Text("导入照片，开始你的创作")
                            .font(.caption).foregroundStyle(.white.opacity(0.7))
                    }
                }
                if isProcessing {
                    VStack {
                        Spacer()
                        HStack(spacing: 8) {
                            ProgressView().tint(.white)
                            Text("正在渲染预览…").font(.caption.weight(.medium)).foregroundStyle(.white)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 9)
                        .background(.black.opacity(0.68), in: Capsule())
                        .padding(.bottom, 15)
                    }
                }
            }
            .aspectRatio(DemoPhotoStudioTheme.previewAspectRatio, contentMode: .fit)
            .overlay(alignment: .bottomLeading) {
                if originalImage != nil {
                    Text(compareMode == .original ? "原图" : (compareMode == .compare ? "前后对比" : "编辑效果"))
                        .font(.caption.weight(.semibold)).foregroundStyle(.white)
                        .padding(.horizontal, 9).padding(.vertical, 6)
                        .background(.black.opacity(0.65), in: Capsule()).padding(12).allowsHitTesting(false)
                }
            }
            if originalImage != nil {
                HStack(spacing: 7) {
                    previewModeButton("效果", mode: .result, icon: "sparkles")
                    previewModeButton("对比", mode: .compare, icon: "slider.horizontal.3")
                    previewModeButton("原图", mode: .original, icon: "photo")
                    Spacer()
                    if let image = editedImage ?? originalImage {
                        Text("\(image.cgImage?.width ?? Int(image.size.width * image.scale)) × \(image.cgImage?.height ?? Int(image.size.height * image.scale))")
                            .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始编辑").font(.title2.weight(.bold))
                    Text("从相册选择照片开始创作")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "wand.and.stars").font(.system(size: 25)).foregroundStyle(accent)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(isLoadingPhoto ? "正在读取照片…" : "从相册导入照片", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.black.opacity(0.85))
            }.disabled(isLoadingPhoto)
            HStack(spacing: 7) {
                featurePill("原生增强", icon: "sparkles")
                featurePill("精细调节", icon: "slider.horizontal.3")
                featurePill("高清导出", icon: "square.and.arrow.down")
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 20))
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 6) {
                ForEach(EditorTab.allCases) { tab in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.icon).font(.system(size: 16, weight: .semibold))
                            Text(tab.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(activeTab == tab ? accent : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(activeTab == tab ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                        .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
                }
            }
            switch activeTab {
            case .enhance: enhancePanel
            case .adjust: adjustmentPanel
            case .compare: comparePanel
            case .export: exportPanel
            }
        }
    }

    private var enhancePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("智能增强", subtitle: "使用 iOS 原生图像算法优化照片")
            Button { applyAutoEnhance() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars").font(.system(size: 22))
                        .frame(width: 45, height: 45)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("一键智能增强").font(.headline)
                        Text("自动优化色彩、曝光与细节").font(.caption).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(.black.opacity(0.85)).padding(13)
                .background(accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain).disabled(isProcessing)

            heading("风格预设", subtitle: "一键应用不同影调")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 155), spacing: 9)], spacing: 9) {
                ForEach(Self.presets) { preset in
                    Button { applyPreset(preset) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: preset.icon).font(.system(size: 17))
                                .foregroundStyle(preset.tint).frame(width: 34, height: 34)
                                .background(preset.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title).font(.body.weight(.semibold))
                                Text(preset.subtitle).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(minLength: 0)
                            if selectedPreset == preset {
                                Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                            }
                        }
                        .padding(10)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedPreset == preset ? accent : .clear, lineWidth: 1.2))
                    }
                    .buttonStyle(.plain).accessibilityElement(children: .combine)
                        .accessibilityAddTraits(selectedPreset == preset ? .isSelected : [])
                        .accessibilityHint("应用此照片风格")
                }
            }
        }
    }

    private var adjustmentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("精细调整", subtitle: "拖动滑块实时查看画面变化")
            VStack(spacing: 17) {
                ForEach(Self.sliderSpecs) { spec in slider(spec) }
            }
            .padding(15)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
        }
    }

    private var comparePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("前后对比", subtitle: "直接拖动预览中的把手调整对比位置")
        }
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("导出作品", subtitle: "以当前编辑效果保存或分享")
            VStack(spacing: 0) {
                exportRow("输出尺寸", value: outputSize, icon: "aspectratio")
                Divider().padding(.leading, 44)
                exportRow("图像格式", value: "JPEG / 系统原生", icon: "doc")
                Divider().padding(.leading, 44)
                exportRow("画质", value: "高质量", icon: "sparkles")
            }
            .padding(.horizontal, 13)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
            Button { saveToPhotos() } label: {
                Label(isSaving ? "正在保存…" : "保存到照片", systemImage: "square.and.arrow.down")
                    .font(.headline.weight(.bold)).frame(maxWidth: .infinity).padding(14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(.black.opacity(0.85))
            }.disabled(isSaving || isProcessing || isRenderPending)
            Button { showShareSheet = true } label: {
                Label("分享作品", systemImage: "square.and.arrow.up")
                    .font(.subheadline.weight(.semibold)).frame(maxWidth: .infinity).padding(13)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
            }.disabled(isProcessing || isRenderPending)
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 11) {
            if originalImage != nil {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Label("更换照片", systemImage: "photo.badge.plus")
                        .font(.body.weight(.semibold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                        .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
                }
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 9).background(.bar)
    }

    private func previewModeButton(_ title: String, mode: PreviewMode, icon: String) -> some View {
        Button { compareMode = mode } label: {
            Label(title, systemImage: icon).font(.caption.weight(.semibold))
                .frame(minHeight: 44).padding(.horizontal, 10)
                .foregroundStyle(compareMode == mode ? Color.primary : Color.secondary)
                .background(compareMode == mode ? Color(uiColor: .tertiarySystemFill) : .clear, in: Capsule())
        }.buttonStyle(.plain)
            .accessibilityAddTraits(compareMode == mode ? .isSelected : [])
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle).font(.subheadline).foregroundStyle(.secondary)
        }
    }

    private func slider(_ spec: DemoSliderSpec) -> some View {
        let value = settings[keyPath: spec.keyPath]
        let display = spec.usesSignedFormat ? signed(value) : decimal(value)
        return VStack(spacing: 7) {
            HStack {
                Label(spec.title, systemImage: spec.icon).font(.subheadline.weight(.semibold))
                Spacer()
                Text(display).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { settings[keyPath: spec.keyPath] },
                set: { settings[keyPath: spec.keyPath] = $0; selectedPreset = .custom; scheduleRender(debounced: true) }
            ), in: spec.range, onEditingChanged: { editing in
                if editing { editingSnapshots[spec.id] = currentSnapshot }
                else if let snapshot = editingSnapshots.removeValue(forKey: spec.id) {
                    if snapshot != currentSnapshot { undoStack.append(snapshot); redoStack.removeAll() }
                }
            }).tint(accent)
                .accessibilityLabel(spec.title)
                .accessibilityValue(display)
                .accessibilityHint("调整照片的\\(spec.title)")
        }
    }

    private func featurePill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.caption2.weight(.medium))
            .padding(.horizontal, 8).padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    private func exportRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).foregroundStyle(accent).frame(width: 20)
            Text(title).font(.subheadline.weight(.medium))
            Spacer()
            Text(value).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 12)
    }

    private var outputSize: String {
        guard let image = editedImage ?? originalImage else { return "—" }
        return "\(image.cgImage?.width ?? Int(image.size.width * image.scale)) × \(image.cgImage?.height ?? Int(image.size.height * image.scale)) px"
    }

    private var currentSnapshot: DemoEditSnapshot { DemoEditSnapshot(settings: settings, preset: selectedPreset, autoEnhanceEnabled: autoEnhanceEnabled) }
    private func restore(_ snapshot: DemoEditSnapshot) { settings = snapshot.settings; selectedPreset = snapshot.preset; autoEnhanceEnabled = snapshot.autoEnhanceEnabled }
    private func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
    private func decimal(_ value: Double) -> String { String(format: "%.2f", value) }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            isLoadingPhoto = true
            defer { isLoadingPhoto = false; pickerItem = nil }
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                alertTitle = "导入失败"
                alertMessage = "无法读取所选照片，请重新选择。"
                return
            }
            pickerItem = nil
            renderToken = UUID()
            isRenderPending = false
            isProcessing = false
            originalImage = image
            editedImage = image
            settings = DemoAdjustmentSettings()
            selectedPreset = .original
            autoEnhanceEnabled = false
            undoStack.removeAll()
            redoStack.removeAll()
            compareMode = .result
        } catch {
            alertTitle = "导入失败"
            alertMessage = "读取照片失败：\(error.localizedDescription)"
        }
    }

    private func applyAutoEnhance() {
        guard originalImage != nil else { return }
        pushUndo()
        autoEnhanceEnabled = true
        scheduleRender()
    }

    private func applyPreset(_ preset: DemoPhotoPreset) {
        pushUndo()
        settings = preset.settings
        selectedPreset = preset
        autoEnhanceEnabled = false
        scheduleRender()
    }

    private func pushUndo() {
        undoStack.append(currentSnapshot)
        if undoStack.count > DemoPhotoStudioTheme.undoHistoryLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        restore(previous)
        scheduleRender()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        restore(next)
        scheduleRender()
    }

    private func resetEdits() {
        applyPreset(.original)
    }

    private func scheduleRender(debounced: Bool = false) {
        guard let originalImage else { return }
        let token = UUID()
        renderToken = token
        isRenderPending = true
        let currentSettings = settings
        let useAutoEnhance = autoEnhanceEnabled
        Task {
            if debounced { try? await Task.sleep(for: .milliseconds(DemoPhotoStudioTheme.renderDebounceMilliseconds)) }
            guard renderToken == token else { return }
            isProcessing = true
            let result = await Task.detached(priority: .userInitiated) {
                DemoImageProcessor.render(originalImage, settings: currentSettings, autoEnhance: useAutoEnhance)
            }.value
            guard renderToken == token else { return }
            editedImage = result ?? originalImage
            isProcessing = false
            isRenderPending = false
        }
    }

    private func saveToPhotos() {
        guard !isProcessing && !isRenderPending else { alertTitle = "请稍候"; alertMessage = "照片仍在处理中，请等待预览更新后再保存。"; return }
        guard let image = editedImage ?? originalImage else { return }
        guard let cgImage = image.cgImage else { alertTitle = "保存失败"; alertMessage = "无法读取当前图像，请重新导入照片。"; return }
        isSaving = true
        Task {
            do {
                try await PhotoLibraryService.shared.save(cgImage)
                alertTitle = "保存成功"
                alertMessage = "照片已成功保存到系统相册。"
            } catch {
                alertTitle = "保存失败"
                alertMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

enum PreviewMode { case result, compare, original }


private enum EditorTab: String, CaseIterable, Identifiable {
    case enhance, adjust, compare, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .enhance: "增强"
        case .adjust: "调节"
        case .compare: "对比"
        case .export: "导出"
        }
    }
    var icon: String {
        switch self {
        case .enhance: "sparkles"
        case .adjust: "slider.horizontal.3"
        case .compare: "square.split.2x1"
        case .export: "square.and.arrow.up"
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
