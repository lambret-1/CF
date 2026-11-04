import SwiftUI
import PhotosUI
import UIKit

struct DemoPhotoAutoEnhanceView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var editedImage: UIImage?
    @State private var settings = DemoAdjustmentSettings()
    @State private var selectedPreset: DemoPhotoPreset = .original
    @State private var activeTab: EditorTab = .adjust
    @State private var compareMode: PreviewMode = .result
    @State private var comparePosition: CGFloat = 0.5
    @State private var autoEnhanceEnabled = false
    @State private var undoStack: [DemoAdjustmentSettings] = []
    @State private var redoStack: [DemoAdjustmentSettings] = []
    @State private var editingSnapshot: DemoAdjustmentSettings?
    @State private var renderToken = UUID()
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var showShareSheet = false
    @State private var selectedAdjustment: AdjustmentControl = .exposure
    @Environment(\.dismiss) private var dismiss

    private let accent = Color(red: 0.43, green: 0.78, blue: 0.68)

    var body: some View {
        VStack(spacing: 0) {
            navigationBar
            if originalImage != nil { quickToolbar }
            preview
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.horizontal, 8)
            if originalImage != nil {
                parameterPanel
                editorTabBar
            } else {
                welcome
                    .padding(.horizontal, 20)
                    .padding(.bottom, 20)
            }
        }
        .background(Color(uiColor: .systemBackground))
        .toolbar(.hidden, for: .navigationBar)
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
    }

    private var navigationBar: some View {
        HStack {
            Button("取消") {
                dismiss()
            }
            .font(.system(size: 16, weight: .medium))
            .foregroundStyle(.primary)
            .padding(.horizontal, 17)
            .padding(.vertical, 8)
            .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
            Spacer()
            Button("完成") {
                saveToPhotos()
            }
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(originalImage == nil ? Color.secondary : Color.black.opacity(0.65))
            .padding(.horizontal, 19)
            .padding(.vertical, 8)
            .background(originalImage == nil ? Color(uiColor: .tertiarySystemFill) : Color(red: 1.0, green: 0.88, blue: 0.48), in: Capsule())
            .disabled(originalImage == nil || isSaving)
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 10)
    }

    private var quickToolbar: some View {
        HStack(spacing: 0) {
            Button { undo() } label: {
                Image(systemName: "arrow.uturn.backward.circle")
                    .font(.system(size: 27, weight: .regular))
                    .frame(width: 48, height: 42)
            }
            .disabled(undoStack.isEmpty)
            .accessibilityLabel("撤销")
            Button { redo() } label: {
                Image(systemName: "arrow.uturn.forward.circle")
                    .font(.system(size: 27, weight: .regular))
                    .frame(width: 48, height: 42)
            }
            .disabled(redoStack.isEmpty)
            .accessibilityLabel("重做")
            Spacer(minLength: 8)
            Text(activeTab.title)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Button {
                compareMode = compareMode == .original ? .result : .original
            } label: {
                Image(systemName: compareMode == .original ? "eye" : "eye.slash")
                    .font(.system(size: 25))
                    .frame(width: 46, height: 42)
            }
            .accessibilityLabel("查看原图")
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Image(systemName: "photo.badge.plus")
                    .font(.system(size: 24))
                    .frame(width: 46, height: 42)
            }
            .accessibilityLabel("更换照片")
            Menu {
                Button("原图对比", systemImage: "rectangle.split.2x1") { compareMode = .compare }
                Button("显示效果", systemImage: "eye") { compareMode = .result }
                Button("重置所有调整", systemImage: "arrow.counterclockwise") { resetEdits() }
                Button("分享照片", systemImage: "square.and.arrow.up") { showShareSheet = true }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 26))
                    .frame(width: 42, height: 42)
            }
            .accessibilityLabel("更多操作")
        }
        .foregroundStyle(Color(uiColor: .secondaryLabel))
        .padding(.horizontal, 18)
        .padding(.bottom, 8)
    }

    private var preview: some View {
        GeometryReader { geo in
            ZStack {
                Color(uiColor: .systemBackground)
                if let originalImage {
                    let displayImage = compareMode == .original ? originalImage : (editedImage ?? originalImage)
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geo.size.width, height: geo.size.height)
                    if compareMode == .compare {
                        Image(uiImage: originalImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .mask(alignment: .leading) {
                                Rectangle().frame(width: geo.size.width * comparePosition)
                            }
                        Rectangle()
                            .fill(.white)
                            .frame(width: 2)
                            .overlay {
                                Image(systemName: "arrow.left.and.right")
                                    .font(.system(size: 10, weight: .bold))
                                    .foregroundStyle(.black)
                                    .padding(7)
                                    .background(.white, in: Circle())
                            }
                            .position(x: geo.size.width * comparePosition, y: geo.size.height / 2)
                    }
                    if isProcessing {
                        VStack {
                            Spacer()
                            ProgressView("正在处理…")
                                .padding(.horizontal, 14).padding(.vertical, 9)
                                .background(.ultraThinMaterial, in: Capsule())
                            Spacer().frame(height: 12)
                        }
                    }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "photo")
                            .font(.system(size: 42, weight: .light))
                            .foregroundStyle(.secondary)
                        Text("选择照片开始编辑")
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(.secondary)
                        PhotosPicker(selection: $pickerItem, matching: .images) {
                            Text("打开照片")
                                .font(.system(size: 15, weight: .semibold))
                                .padding(.horizontal, 22).padding(.vertical, 11)
                                .background(Color(uiColor: .label), in: Capsule())
                                .foregroundStyle(Color(uiColor: .systemBackground))
                        }
                    }
                }
            }
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                guard compareMode == .compare else { return }
                comparePosition = min(max(value.location.x / max(geo.size.width, 1), 0.03), 0.97)
            })
        }
        .clipped()
    }

    private var parameterPanel: some View {
        VStack(spacing: 13) {
            if activeTab == .adjust {
                HStack(spacing: 0) {
                    ForEach(AdjustmentControl.allCases) { control in
                        Button {
                            if control == .auto { applyAutoEnhance() }
                            else { selectedAdjustment = control }
                        } label: {
                            VStack(spacing: 5) {
                                Image(systemName: control.icon)
                                    .font(.system(size: 22, weight: .regular))
                                    .frame(width: 62, height: 62)
                                    .background(selectedAdjustment == control ? Color(uiColor: .tertiarySystemFill) : .clear, in: Circle())
                                    .overlay(Circle().stroke(Color(uiColor: .tertiaryLabel).opacity(selectedAdjustment == control ? 0 : 0.65), lineWidth: 1.5))
                                Text(control.title)
                                    .font(.system(size: 10, weight: selectedAdjustment == control ? .semibold : .regular))
                            }
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 8)
                Slider(value: selectedAdjustmentBinding, in: selectedAdjustment.range, onEditingChanged: { editing in
                    if editing {
                        editingSnapshot = settings
                    } else if let snapshot = editingSnapshot {
                        if snapshot != settings {
                            undoStack.append(snapshot)
                            if undoStack.count > 40 { undoStack.removeFirst() }
                            redoStack.removeAll()
                        }
                        editingSnapshot = nil
                    }
                })
                    .tint(.primary)
                    .padding(.horizontal, 26)
                    .accessibilityLabel(selectedAdjustment.title)
                Text(selectedAdjustment.title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            } else if activeTab == .filters {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 12) {
                        ForEach(DemoPhotoPreset.allCases.filter { $0 != .custom }) { preset in
                            Button { applyPreset(preset) } label: {
                                VStack(spacing: 7) {
                                    RoundedRectangle(cornerRadius: 13)
                                        .fill(preset.tint.opacity(0.22))
                                        .frame(width: 58, height: 58)
                                        .overlay(Image(systemName: preset.icon).font(.system(size: 21)).foregroundStyle(preset.tint))
                                        .overlay(RoundedRectangle(cornerRadius: 13).stroke(selectedPreset == preset ? Color.primary : .clear, lineWidth: 2))
                                    Text(preset.title).font(.system(size: 10, weight: .medium)).foregroundStyle(.primary)
                                }
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 18)
                }
                .frame(height: 88)
            } else if activeTab == .crop {
                HStack(spacing: 25) {
                    cropTool("自由", icon: "crop")
                    cropTool("旋转", icon: "rotate.right")
                    cropTool("翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right")
                    cropTool("比例", icon: "aspectratio")
                }
                .frame(height: 76)
            } else {
                HStack(spacing: 18) {
                    Image(systemName: activeTab.icon).font(.system(size: 24))
                    VStack(alignment: .leading, spacing: 3) {
                        Text(activeTab.title).font(.system(size: 13, weight: .semibold))
                        Text("功能入口已预留，后续可直接扩展")
                            .font(.system(size: 10)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: 76)
            }
        }
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var selectedAdjustmentBinding: Binding<Double> {
        Binding(
            get: { settings[keyPath: selectedAdjustment.keyPath] },
            set: { value in
                settings[keyPath: selectedAdjustment.keyPath] = value
                selectedPreset = .custom
                autoEnhanceEnabled = false
                scheduleRender(debounced: true)
            }
        )
    }

    private func cropTool(_ title: String, icon: String) -> some View {
        Button {
            alertMessage = "\(title)工具将在裁剪引擎接入阶段启用。"
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
                                .font(.system(size: 23, weight: activeTab == tab ? .semibold : .regular))
                                .frame(height: 27)
                            Text(tab.title)
                                .font(.system(size: 11, weight: activeTab == tab ? .semibold : .regular))
                        }
                        .foregroundStyle(activeTab == tab ? .primary : Color(uiColor: .tertiaryLabel))
                        .frame(minWidth: 88)
                        .padding(.top, 9)
                        .padding(.bottom, 7)
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
        .padding(.bottom, 22)
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

    private var editor: some View {
        EmptyView()
    }

    private var enhancePanel: some View { EmptyView() }

    private var adjustmentPanel: some View { EmptyView() }

    private var comparePanel: some View { EmptyView() }

    private var exportPanel: some View { EmptyView() }

    private func previewModeButton(_ title: String, mode: PreviewMode, icon: String) -> some View {
        Button { compareMode = mode } label: {
            Label(title, systemImage: icon).font(.system(size: 10, weight: .semibold))
        }
    }

    private func heading(_ title: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 16, weight: .bold))
            Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary)
        }
    }

    private func placeholder(_ title: String, detail: String, icon: String) -> some View {
        HStack(spacing: 11) {
            Image(systemName: icon).font(.system(size: 15)).foregroundStyle(.secondary)
                .frame(width: 33, height: 33).background(Color(uiColor: .tertiarySystemFill), in: RoundedRectangle(cornerRadius: 9))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 12, weight: .semibold))
                Text(detail).font(.system(size: 9)).foregroundStyle(.secondary)
            }
            Spacer()
            Text("规划中").font(.system(size: 9, weight: .semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.vertical, 5)
                .background(Color(uiColor: .tertiarySystemFill), in: Capsule())
        }.padding(.vertical, 9).opacity(0.78)
    }

    private func slider(_ title: String, icon: String, keyPath: WritableKeyPath<DemoAdjustmentSettings, Double>, range: ClosedRange<Double>, display: String) -> some View {
        VStack(spacing: 7) {
            HStack {
                Label(title, systemImage: icon).font(.system(size: 11, weight: .semibold))
                Spacer()
                Text(display).font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
            }
            Slider(value: Binding(
                get: { settings[keyPath: keyPath] },
                set: { settings[keyPath: keyPath] = $0; selectedPreset = .custom; scheduleRender(debounced: true) }
            ), in: range, onEditingChanged: { editing in
                if editing { editingSnapshot = settings }
                else if let snapshot = editingSnapshot {
                    if snapshot != settings { undoStack.append(snapshot); redoStack.removeAll() }
                    editingSnapshot = nil
                }
            }).tint(accent)
        }
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

    private var outputSize: String {
        guard let image = editedImage ?? originalImage else { return "—" }
        return "\(Int(image.size.width)) × \(Int(image.size.height))"
    }

    private func signed(_ value: Double) -> String { String(format: "%+.2f", value) }
    private func decimal(_ value: Double) -> String { String(format: "%.2f", value) }

    @MainActor
    private func loadPhoto(_ item: PhotosPickerItem) async {
        do {
            guard let data = try await item.loadTransferable(type: Data.self),
                  let image = UIImage(data: data) else {
                alertMessage = "无法读取所选照片，请重新选择。"
                return
            }
            pickerItem = nil
            renderToken = UUID()
            originalImage = image
            editedImage = image
            settings = DemoAdjustmentSettings()
            selectedPreset = .original
            autoEnhanceEnabled = false
            undoStack.removeAll()
            redoStack.removeAll()
            compareMode = .result
        } catch {
            alertMessage = "读取照片失败：\(error.localizedDescription)"
        }
    }

    private func applyAutoEnhance() {
        guard originalImage != nil else { return }
        pushUndo()
        settings = DemoAdjustmentSettings()
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
        undoStack.append(settings)
        if undoStack.count > 40 { undoStack.removeFirst() }
        redoStack.removeAll()
    }

    private func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(settings)
        settings = previous
        autoEnhanceEnabled = false
        selectedPreset = .custom
        scheduleRender()
    }

    private func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(settings)
        settings = next
        autoEnhanceEnabled = false
        selectedPreset = .custom
        scheduleRender()
    }

    private func resetEdits() {
        applyPreset(.original)
        compareMode = .result
    }

    private func scheduleRender(debounced: Bool = false) {
        guard let originalImage else { return }
        let token = UUID()
        renderToken = token
        isProcessing = true
        let currentSettings = settings
        let useAutoEnhance = autoEnhanceEnabled
        Task {
            if debounced { try? await Task.sleep(for: .milliseconds(100)) }
            guard renderToken == token else { return }
            let result = await Task.detached(priority: .userInitiated) {
                DemoImageProcessor.render(originalImage, settings: currentSettings, autoEnhance: useAutoEnhance)
            }.value
            guard renderToken == token else { return }
            editedImage = result ?? originalImage
            isProcessing = false
        }
    }

    private func saveToPhotos() {
        guard let image = editedImage ?? originalImage else { return }
        guard let cgImage = image.cgImage else { alertMessage = "无法读取当前图像，请重新导入照片。"; return }
        isSaving = true
        Task {
            do {
                try await PhotoLibraryService.shared.save(cgImage)
                alertMessage = "照片已成功保存到系统相册。"
            } catch {
                alertMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}

private enum PreviewMode { case result, compare, original }

private enum EditorTab: String, CaseIterable, Identifiable {
    case adjust, filters, crop
    var id: String { rawValue }
    var title: String {
        switch self {
        case .adjust: "调整"
        case .filters: "滤镜"
        case .crop: "裁剪"
        }
    }
    var icon: String {
        switch self {
        case .adjust: "slider.horizontal.3"
        case .filters: "camera.filters"
        case .crop: "crop"
        }
    }
}

private enum AdjustmentControl: String, CaseIterable, Identifiable {
    case auto, exposure, contrast, saturation, brightness
    var id: String { rawValue }
    var title: String {
        switch self {
        case .auto: "自动"
        case .exposure: "曝光"
        case .contrast: "对比度"
        case .saturation: "饱和度"
        case .brightness: "亮度"
        }
    }
    var icon: String {
        switch self {
        case .auto: "wand.and.stars"
        case .exposure: "plusminus.circle"
        case .contrast: "circle.lefthalf.filled"
        case .saturation: "drop.halffull"
        case .brightness: "sun.max"
        }
    }
    var range: ClosedRange<Double> {
        switch self {
        case .auto: -2...2
        case .exposure: -2...2
        case .contrast: 0.5...1.8
        case .saturation: 0...2
        case .brightness: -0.5...0.5
        }
    }
    var keyPath: WritableKeyPath<DemoAdjustmentSettings, Double> {
        switch self {
        case .auto, .exposure: \.exposure
        case .contrast: \.contrast
        case .saturation: \.saturation
        case .brightness: \.brightness
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
