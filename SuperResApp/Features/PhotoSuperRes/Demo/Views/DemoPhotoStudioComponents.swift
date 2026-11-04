import SwiftUI
import PhotosUI
import UIKit

// MARK: - Theme

private enum StudioTheme {
    static let accent = Color(red: 0.43, green: 0.78, blue: 0.68)
    static let onAccent = Color.black.opacity(0.85)
    static let previewBackground = Color(red: 0.10, green: 0.12, blue: 0.13)

    static let previewAspectFallback: CGFloat = 4.0 / 3.0
    static let previewAspectMin: CGFloat = 0.6
    static let previewAspectMax: CGFloat = 2.0
    static let minPreviewHeight: CGFloat = 200

    static let handleDiameter: CGFloat = 32
    static let handleHitSize: CGFloat = 44
    static let dividerWidth: CGFloat = 2
    static let compareMin: CGFloat = 0.03
    static let compareMax: CGFloat = 0.97
    static let compareStep: CGFloat = 0.05

    static let undoLimit = 40
    static let renderDebounce: Duration = .milliseconds(90)

    static let cornerRadiusLarge: CGFloat = 23
    static let contentPadding: CGFloat = 18
    static let touchSize: CGFloat = 44
}

// MARK: - Snapshot & Specs

private struct EditSnapshot: Equatable {
    var settings: DemoAdjustmentSettings
    var preset: DemoPhotoPreset
    var autoEnhance: Bool
}

private struct EditingSession {
    var settings: DemoAdjustmentSettings
    var preset: DemoPhotoPreset
    var autoEnhance: Bool
}

private struct SliderSpec: Identifiable {
    let id: String
    let title: String
    let icon: String
    let keyPath: WritableKeyPath<DemoAdjustmentSettings, Double>
    let range: ClosedRange<Double>
    let format: (Double) -> String

    static func signed(_ keyPath: WritableKeyPath<DemoAdjustmentSettings, Double>,
                       title: String, icon: String, range: ClosedRange<Double>) -> SliderSpec {
        SliderSpec(id: title, title: title, icon: icon, keyPath: keyPath, range: range) {
            String(format: "%+.2f", $0)
        }
    }

    static func decimal(_ keyPath: WritableKeyPath<DemoAdjustmentSettings, Double>,
                        title: String, icon: String, range: ClosedRange<Double>) -> SliderSpec {
        SliderSpec(id: title, title: title, icon: icon, keyPath: keyPath, range: range) {
            String(format: "%.2f", $0)
        }
    }
}

private struct SendableImage: @unchecked Sendable {
    let image: UIImage?
}

private struct StudioAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

// MARK: - Main View

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

    @State private var undoStack: [EditSnapshot] = []
    @State private var redoStack: [EditSnapshot] = []
    @State private var editingSessions: [String: EditingSession] = [:]

    @State private var renderToken = 0
    @State private var renderTask: Task<Void, Never>?
    @State private var isProcessing = false
    @State private var isLoading = false
    @State private var isSaving = false

    @State private var alert: StudioAlert?
    @State private var showShareSheet = false
    @State private var showAutoEnhanceConfirm = false

    @Environment(\.dismiss) private var dismiss

    private static let presets: [DemoPhotoPreset] =
        DemoPhotoPreset.allCases.filter { $0 != .custom }

    private let accent = StudioTheme.accent

    private var sliderSpecs: [SliderSpec] {
        [
            .signed(\.exposure,    title: "曝光",   icon: "sun.max",                 range: -2...2),
            .signed(\.brightness,  title: "亮度",   icon: "sun.min",                 range: -0.5...0.5),
            .decimal(\.contrast,   title: "对比度", icon: "circle.lefthalf.filled",  range: 0.5...1.8),
            .decimal(\.saturation, title: "饱和度", icon: "drop",                    range: 0...2),
            .signed(\.temperature, title: "色温",   icon: "thermometer.medium",      range: -100...100),
            .signed(\.highlights,  title: "高光",   icon: "sun.max.fill",            range: -1...1),
            .signed(\.shadows,     title: "阴影",   icon: "moon",                    range: -1...1),
            .decimal(\.sharpness,  title: "锐度",   icon: "viewfinder",              range: 0...2)
        ]
    }

    // MARK: Body

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            ScrollView(showsIndicators: false) {
                VStack(spacing: 20) {
                    preview
                    if originalImage == nil { welcome } else { editor }
                }
                .padding(.horizontal, StudioTheme.contentPadding)
                .padding(.top, 12)
                .padding(.bottom, 22)
            }
            if originalImage != nil {
                bottomBar
            }
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                await loadPhoto(item)
                pickerItem = nil
            }
        }
        .alert(
            alert?.title ?? "",
            isPresented: Binding(
                get: { alert != nil },
                set: { if !$0 { alert = nil } }
            ),
            presenting: alert
        ) { _ in
            Button("好", role: .cancel) {}
        } message: { content in
            Text(content.message)
        }
        .sheet(isPresented: $showShareSheet) {
            if let image = editedImage ?? originalImage {
                DemoShareSheet(items: [image])
            }
        }
        .confirmationDialog(
            "智能增强将覆盖当前手动调节",
            isPresented: $showAutoEnhanceConfirm,
            titleVisibility: .visible
        ) {
            Button("继续增强", role: .destructive) { performAutoEnhance() }
            Button("取消", role: .cancel) {}
        }
        .onDisappear { renderTask?.cancel() }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 4) {
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(width: StudioTheme.touchSize, height: StudioTheme.touchSize)
                    .contentShape(Rectangle())
            }
            .accessibilityLabel("关闭")

            VStack(alignment: .leading, spacing: 2) {
                Text("PHOTO STUDIO")
                    .font(.caption2.weight(.black))
                    .tracking(2)
                Text("智能照片编辑")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            toolbarIconButton(systemName: "arrow.uturn.backward", label: "撤销", disabled: undoStack.isEmpty) { undo() }
            toolbarIconButton(systemName: "arrow.uturn.forward",  label: "重做", disabled: redoStack.isEmpty) { redo() }
            Button("重置") { resetEdits() }
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .frame(minHeight: StudioTheme.touchSize)
                .contentShape(Rectangle())
                .disabled(originalImage == nil)
                .accessibilityLabel("重置所有调节")
        }
        .padding(.leading, 4)
        .padding(.trailing, 10)
        .padding(.vertical, 2)
        .background(.bar)
    }

    private func toolbarIconButton(systemName: String, label: String,
                                   disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 17, weight: .medium))
                .frame(width: StudioTheme.touchSize, height: StudioTheme.touchSize)
                .contentShape(Rectangle())
        }
        .disabled(disabled)
        .accessibilityLabel(label)
    }

    // MARK: Preview

    private var preview: some View {
        VStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: StudioTheme.cornerRadiusLarge, style: .continuous)
                    .fill(StudioTheme.previewBackground)
                if let originalImage {
                    previewContent(original: originalImage)
                } else {
                    previewEmpty
                }
                if isLoading {
                    Color.black.opacity(0.4)
                    ProgressView().tint(.white)
                } else if isProcessing {
                    processingOverlay
                }
            }
            .aspectRatio(previewAspect, contentMode: .fit)
            .frame(minHeight: StudioTheme.minPreviewHeight)
            .clipShape(RoundedRectangle(cornerRadius: StudioTheme.cornerRadiusLarge, style: .continuous))
            .overlay(alignment: .bottomLeading) {
                if originalImage != nil {
                    modeBadge.padding(12)
                }
            }

            if originalImage != nil {
                previewControls
            }
        }
    }

    private var previewAspect: CGFloat {
        guard let image = editedImage ?? originalImage, image.size.height > 0 else {
            return StudioTheme.previewAspectFallback
        }
        let ratio = image.size.width / image.size.height
        return min(max(ratio, StudioTheme.previewAspectMin), StudioTheme.previewAspectMax)
    }

    private func previewContent(original: UIImage) -> some View {
        let display = compareMode == .original ? original : (editedImage ?? original)
        return GeometryReader { geo in
            ZStack {
                Image(uiImage: display)
                    .resizable()
                    .scaledToFill()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()

                if compareMode == .compare {
                    Image(uiImage: original)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: geo.size.width * comparePosition)
                        }
                    compareHandle(in: geo.size)
                }
            }
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard compareMode == .compare else { return }
                        let raw = value.location.x / max(geo.size.width, 1)
                        comparePosition = min(max(raw, StudioTheme.compareMin), StudioTheme.compareMax)
                    }
            )
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(compareMode == .compare ? "前后对比" : "照片预览")
            .accessibilityValue(compareMode == .compare ? "\(Int(comparePosition * 100))%" : "")
            .accessibilityAdjustableAction { direction in
                guard compareMode == .compare else { return }
                switch direction {
                case .increment:
                    comparePosition = min(comparePosition + StudioTheme.compareStep, StudioTheme.compareMax)
                case .decrement:
                    comparePosition = max(comparePosition - StudioTheme.compareStep, StudioTheme.compareMin)
                @unknown default:
                    break
                }
            }
        }
    }

    private func compareHandle(in size: CGSize) -> some View {
        let x = size.width * comparePosition
        return ZStack {
            Rectangle()
                .fill(.white)
                .frame(width: StudioTheme.dividerWidth, height: size.height)
            Circle()
                .fill(.white)
                .frame(width: StudioTheme.handleDiameter, height: StudioTheme.handleDiameter)
                .overlay {
                    Image(systemName: "arrow.left.and.right")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.black)
                }
                .frame(width: StudioTheme.handleHitSize, height: StudioTheme.handleHitSize)
                .contentShape(Rectangle())
        }
        .position(x: x, y: size.height / 2)
        .allowsHitTesting(false)
    }

    private var previewEmpty: some View {
        VStack(spacing: 10) {
            Image(systemName: "photo.on.rectangle.angled")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(accent.opacity(0.85))
            Text("暂无照片")
                .font(.footnote)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private var processingOverlay: some View {
        VStack {
            Spacer()
            HStack(spacing: 8) {
                ProgressView().tint(.white)
                Text("正在渲染…")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.black.opacity(0.68), in: Capsule())
            .padding(.bottom, 15)
        }
    }

    private var modeBadge: some View {
        Text(compareMode == .original ? "原图" : (compareMode == .compare ? "对比" : "效果"))
            .font(.caption2.weight(.bold))
            .foregroundStyle(.white)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.black.opacity(0.55), in: Capsule())
    }

    private var previewControls: some View {
        HStack(spacing: 7) {
            previewModeButton("效果", mode: .result, icon: "sparkles")
            previewModeButton("对比", mode: .compare, icon: "slider.horizontal.3")
            previewModeButton("原图", mode: .original, icon: "photo")
            Spacer()
            Text(pixelSize)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
    }

    private func previewModeButton(_ title: String, mode: PreviewMode, icon: String) -> some View {
        Button {
            compareMode = mode
        } label: {
            Label(title, systemImage: icon)
                .font(.caption.weight(.semibold))
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .foregroundStyle(compareMode == mode ? Color.primary : Color.secondary)
                .background(compareMode == mode ? Color(uiColor: .tertiarySystemFill) : .clear, in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(compareMode == mode ? .isSelected : [])
    }

    private var pixelSize: String {
        guard let image = editedImage ?? originalImage, let cg = image.cgImage else { return "—" }
        return "\(cg.width) × \(cg.height)"
    }

    // MARK: Welcome

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("开始编辑")
                        .font(.headline)
                    Text("选择一张照片，解锁完整编辑工具")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "wand.and.stars")
                    .font(.system(size: 25))
                    .foregroundStyle(accent)
            }
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("从相册导入照片", systemImage: "plus")
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(StudioTheme.onAccent)
            }
            HStack(spacing: 7) {
                featurePill("原生增强", icon: "sparkles")
                featurePill("精细调节", icon: "slider.horizontal.3")
                featurePill("高清导出", icon: "square.and.arrow.down")
            }
        }
        .padding(18)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 20))
    }

    private func featurePill(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 8)
            .padding(.vertical, 7)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
    }

    // MARK: Editor

    private var editor: some View {
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 6) {
                ForEach(EditorTab.allCases) { tab in
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab }
                    } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 16, weight: .semibold))
                            Text(tab.title)
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(activeTab == tab ? accent : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 11)
                        .background(activeTab == tab ? accent.opacity(0.12) : .clear,
                                    in: RoundedRectangle(cornerRadius: 12))
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(activeTab == tab ? .isSelected : [])
                }
            }
            switch activeTab {
            case .enhance: enhancePanel
            case .adjust:  adjustmentPanel
            case .compare: comparePanel
            case .export:  exportPanel
            }
        }
    }

    private var enhancePanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("智能增强", subtitle: "使用 iOS 原生图像算法优化照片")
            Button { requestAutoEnhance() } label: {
                HStack(spacing: 12) {
                    Image(systemName: "wand.and.stars")
                        .font(.system(size: 22))
                        .frame(width: 45, height: 45)
                        .background(.white.opacity(0.18), in: RoundedRectangle(cornerRadius: 12))
                    VStack(alignment: .leading, spacing: 3) {
                        Text("一键智能增强")
                            .font(.subheadline.weight(.bold))
                        Text("自动优化色彩、曝光与细节")
                            .font(.caption2)
                            .opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(StudioTheme.onAccent)
                .padding(13)
                .background(accent, in: RoundedRectangle(cornerRadius: 16))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isProcessing)

            heading("风格预设", subtitle: "一键应用不同影调")
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 9)], spacing: 9) {
                ForEach(Self.presets) { preset in
                    presetCell(preset)
                }
            }
        }
    }

    private func presetCell(_ preset: DemoPhotoPreset) -> some View {
        let isSelected = selectedPreset == preset
        return Button { applyPreset(preset) } label: {
            HStack(spacing: 9) {
                Image(systemName: preset.icon)
                    .font(.system(size: 17))
                    .foregroundStyle(preset.tint)
                    .frame(width: 34, height: 34)
                    .background(preset.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(preset.title)
                        .font(.caption.weight(.semibold))
                    Text(preset.subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(accent)
                }
            }
            .padding(10)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 13))
            .overlay(
                RoundedRectangle(cornerRadius: 13)
                    .stroke(isSelected ? accent : .clear, lineWidth: 1.2)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(preset.title)，\(preset.subtitle)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var adjustmentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("精细调整", subtitle: "拖动滑块实时查看画面变化")
            VStack(spacing: 17) {
                ForEach(sliderSpecs) { spec in
                    sliderRow(spec)
                }
            }
            .padding(15)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 17))
        }
    }

    private func sliderRow(_ spec: SliderSpec) -> some View {
        VStack(spacing: 7) {
            HStack {
                Label(spec.title, systemImage: spec.icon)
                    .font(.caption.weight(.semibold))
                Spacer()
                Text(spec.format(settings[keyPath: spec.keyPath]))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(
                value: Binding(
                    get: { settings[keyPath: spec.keyPath] },
                    set: { newValue in
                        settings[keyPath: spec.keyPath] = newValue
                        selectedPreset = .custom
                        scheduleRender()
                    }
                ),
                in: spec.range,
                onEditingChanged: { editing in
                    if editing {
                        editingSessions[spec.id] = EditingSession(
                            settings: settings,
                            preset: selectedPreset,
                            autoEnhance: autoEnhanceEnabled
                        )
                    } else if let session = editingSessions.removeValue(forKey: spec.id) {
                        if session.settings != settings {
                            undoStack.append(EditSnapshot(
                                settings: session.settings,
                                preset: session.preset,
                                autoEnhance: session.autoEnhance
                            ))
                            if undoStack.count > StudioTheme.undoLimit { undoStack.removeFirst() }
                            redoStack.removeAll()
                        }
                    }
                }
            )
            .tint(accent)
            .accessibilityLabel(spec.title)
            .accessibilityValue(spec.format(settings[keyPath: spec.keyPath]))
        }
    }

    private var comparePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("前后对比", subtitle: "拖动预览中的分割线查看差异")
            HStack(spacing: 9) {
                infoCard("原始照片", detail: "保留导入版本", icon: "photo")
                infoCard("编辑结果", detail: "当前调整效果", icon: "sparkles")
            }
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { compareMode = .compare }
            } label: {
                Label("开启滑动对比", systemImage: "arrow.left.and.right")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(13)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(compareMode == .compare)
        }
    }

    private func infoCard(_ title: String, detail: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Image(systemName: icon)
                .font(.system(size: 18))
                .foregroundStyle(accent)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(13)
        .background(Color(uiColor: .secondarySystemGroupedBackground),
                    in: RoundedRectangle(cornerRadius: 14))
    }

    private var exportPanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("导出作品", subtitle: "以当前编辑效果分享")
            VStack(spacing: 0) {
                exportRow("输出尺寸", value: pixelSize, icon: "aspectratio")
                Divider().padding(.leading, 44)
                exportRow("图像格式", value: "JPEG", icon: "doc")
                Divider().padding(.leading, 44)
                exportRow("画质", value: "高质量", icon: "sparkles")
            }
            .padding(.horizontal, 13)
            .background(Color(uiColor: .secondarySystemGroupedBackground),
                        in: RoundedRectangle(cornerRadius: 15))
            Button { showShareSheet = true } label: {
                Label("分享作品", systemImage: "square.and.arrow.up")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(13)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 13))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func exportRow(_ title: String, value: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon)
                .foregroundStyle(accent)
                .frame(width: 20)
            Text(title)
                .font(.caption.weight(.medium))
            Spacer()
            Text(value)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 12)
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.headline)
            Text(subtitle)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 11) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("更换照片", systemImage: "photo.badge.plus")
                    .font(.footnote.weight(.semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 13)
                    .background(Color(uiColor: .secondarySystemGroupedBackground),
                                in: RoundedRectangle(cornerRadius: 13))
                    .contentShape(Rectangle())
            }
            Button { saveToPhotos() } label: {
                HStack(spacing: 7) {
                    if isSaving {
                        ProgressView().tint(StudioTheme.onAccent)
                    } else {
                        Image(systemName: "square.and.arrow.down")
                    }
                    Text(isSaving ? "保存中…" : "保存")
                }
                .font(.footnote.weight(.bold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(accent, in: RoundedRectangle(cornerRadius: 13))
                .foregroundStyle(StudioTheme.onAccent)
                .contentShape(Rectangle())
            }
            .disabled(isSaving || isProcessing || isLoading)
        }
        .padding(.horizontal, 18)
        .padding(.top, 10)
        .padding(.bottom, 9)
        .background(.bar)
    }

    // MARK: Actions

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        isLoading = true
        defer { isLoading = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                alert = StudioAlert(title: "导入失败", message: "无法读取所选照片，请重新选择。")
                return
            }
            renderTask?.cancel()
            renderToken += 1
            originalImage = image
            editedImage = image
            settings = DemoAdjustmentSettings()
            selectedPreset = .original
            autoEnhanceEnabled = false
            undoStack.removeAll()
            redoStack.removeAll()
            editingSessions.removeAll()
            compareMode = .result
            comparePosition = 0.5
        } catch {
            alert = StudioAlert(title: "导入失败", message: error.localizedDescription)
        }
    }

    private func requestAutoEnhance() {
        if settings == DemoAdjustmentSettings() && !autoEnhanceEnabled {
            performAutoEnhance()
        } else {
            showAutoEnhanceConfirm = true
        }
    }

    private func performAutoEnhance() {
        guard originalImage != nil else { return }
        pushUndo()
        settings = DemoAdjustmentSettings()
        selectedPreset = .custom
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

    private var currentSnapshot: EditSnapshot {
        EditSnapshot(settings: settings, preset: selectedPreset, autoEnhance: autoEnhanceEnabled)
    }

    private func pushUndo() {
        undoStack.append(currentSnapshot)
        if undoStack.count > StudioTheme.undoLimit { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(currentSnapshot)
        settings = previous.settings
        selectedPreset = previous.preset
        autoEnhanceEnabled = previous.autoEnhance
        scheduleRender()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(currentSnapshot)
        settings = next.settings
        selectedPreset = next.preset
        autoEnhanceEnabled = next.autoEnhance
        scheduleRender()
    }

    private func resetEdits() {
        guard originalImage != nil else { return }
        pushUndo()
        settings = DemoAdjustmentSettings()
        selectedPreset = .original
        autoEnhanceEnabled = false
        scheduleRender()
    }

    private func scheduleRender() {
        guard let originalImage else { return }
        renderTask?.cancel()
        renderToken += 1
        let token = renderToken
        let currentSettings = settings
        let useAutoEnhance = autoEnhanceEnabled
        let imageWrapper = SendableImage(image: originalImage)

        renderTask = Task {
            try? await Task.sleep(for: StudioTheme.renderDebounce)
            if Task.isCancelled { return }
            isProcessing = true
            let result: UIImage? = await Task.detached(priority: .userInitiated) {
                guard let img = imageWrapper.image else { return nil }
                let rendered = DemoImageProcessor.render(img,
                                                        settings: currentSettings,
                                                        autoEnhance: useAutoEnhance)
                return SendableImage(image: rendered).image
            }.value
            if renderToken != token { return }
            editedImage = result ?? originalImage
            isProcessing = false
        }
    }

    private func saveToPhotos() {
        guard !isProcessing, !isLoading else { return }
        guard let image = editedImage ?? originalImage else {
            alert = StudioAlert(title: "保存失败", message: "没有可保存的照片。")
            return
        }
        guard let cgImage = image.cgImage else {
            alert = StudioAlert(title: "保存失败", message: "无法处理该照片，请重试。")
            return
        }
        isSaving = true
        Task {
            do {
                try await PhotoLibraryService.shared.save(cgImage)
                alert = StudioAlert(title: "已保存", message: "照片已保存到系统相册。")
            } catch {
                alert = StudioAlert(title: "保存失败", message: error.localizedDescription)
            }
            isSaving = false
        }
    }
}

// MARK: - Supporting Types

private enum PreviewMode { case result, compare, original }

private enum EditorTab: String, CaseIterable, Identifiable {
    case enhance, adjust, compare, export
    var id: String { rawValue }
    var title: String {
        switch self {
        case .enhance: "增强"
        case .adjust:  "调节"
        case .compare: "对比"
        case .export:  "导出"
        }
    }
    var icon: String {
        switch self {
        case .enhance: "sparkles"
        case .adjust:  "slider.horizontal.3"
        case .compare: "square.split.2x1"
        case .export:  "square.and.arrow.up"
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