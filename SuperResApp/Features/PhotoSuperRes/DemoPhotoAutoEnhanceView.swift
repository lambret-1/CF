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
    @State private var undoStack: [DemoAdjustmentSettings] = []
    @State private var redoStack: [DemoAdjustmentSettings] = []
    @State private var editingSnapshot: DemoAdjustmentSettings?
    @State private var renderToken = UUID()
    @State private var isProcessing = false
    @State private var isSaving = false
    @State private var alertMessage: String?
    @State private var showShareSheet = false

    private let accent = Color(red: 0.43, green: 0.78, blue: 0.68)

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
            bottomBar
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .toolbar(.hidden, for: .navigationBar)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPhoto(item) }
        }
        .alert("照片工作室", isPresented: Binding(
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

    private var toolbar: some View {
        HStack(spacing: 17) {
            VStack(alignment: .leading, spacing: 2) {
                Text("PHOTO STUDIO")
                    .font(.system(size: 12, weight: .black, design: .rounded))
                    .tracking(2)
                Text("智能照片编辑")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button { undo() } label: { Image(systemName: "arrow.uturn.backward") }
                .disabled(undoStack.isEmpty)
                .accessibilityLabel("撤销")
            Button { redo() } label: { Image(systemName: "arrow.uturn.forward") }
                .disabled(redoStack.isEmpty)
                .accessibilityLabel("重做")
            Button("重置") { resetEdits() }
                .font(.system(size: 12, weight: .semibold))
                .disabled(originalImage == nil)
        }
        .font(.system(size: 17, weight: .medium))
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
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Image(uiImage: compareMode == .original ? originalImage : (editedImage ?? originalImage))
                                .resizable().scaledToFit()
                                .frame(width: geo.size.width, height: geo.size.height)
                            if compareMode == .compare {
                                Image(uiImage: originalImage)
                                    .resizable().scaledToFit()
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
                        }
                        .contentShape(Rectangle())
                        .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                            guard compareMode == .compare else { return }
                            comparePosition = min(max(value.location.x / max(geo.size.width, 1), 0.03), 0.97)
                        })
                    }
                    .padding(5)
                } else {
                    VStack(spacing: 13) {
                        Image(systemName: "photo.on.rectangle.angled")
                            .font(.system(size: 43, weight: .light)).foregroundStyle(accent)
                        Text("让每一张照片，都值得珍藏")
                            .font(.system(size: 15, weight: .semibold)).foregroundStyle(.white)
                        Text("导入照片，开始你的创作")
                            .font(.system(size: 12)).foregroundStyle(.white.opacity(0.55))
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
            .frame(height: 305)
            .overlay(alignment: .topLeading) {
                if originalImage != nil {
                    Text(compareMode == .original ? "原图" : (compareMode == .compare ? "前后对比" : "编辑效果"))
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 10).padding(.vertical, 7)
                        .background(.black.opacity(0.55), in: Capsule()).padding(15)
                }
            }
            if originalImage != nil {
                HStack(spacing: 7) {
                    previewModeButton("效果", mode: .result, icon: "sparkles")
                    previewModeButton("对比", mode: .compare, icon: "slider.horizontal.3")
                    previewModeButton("原图", mode: .original, icon: "photo")
                    Spacer()
                    if let image = editedImage ?? originalImage {
                        Text("\(Int(image.size.width)) × \(Int(image.size.height))")
                            .font(.system(size: 10, design: .monospaced)).foregroundStyle(.secondary)
                    }
                }
            }
        }
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
        VStack(alignment: .leading, spacing: 17) {
            HStack(spacing: 6) {
                ForEach(EditorTab.allCases) { tab in
                    Button { withAnimation(.easeInOut(duration: 0.2)) { activeTab = tab } } label: {
                        VStack(spacing: 6) {
                            Image(systemName: tab.icon).font(.system(size: 16, weight: .semibold))
                            Text(tab.title).font(.system(size: 10, weight: .semibold))
                        }
                        .foregroundStyle(activeTab == tab ? accent : Color.secondary)
                        .frame(maxWidth: .infinity).padding(.vertical, 11)
                        .background(activeTab == tab ? accent.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
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
                        Text("一键智能增强").font(.system(size: 15, weight: .bold))
                        Text("自动优化色彩、曝光与细节").font(.system(size: 10)).opacity(0.8)
                    }
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .foregroundStyle(.black.opacity(0.85)).padding(13)
                .background(accent, in: RoundedRectangle(cornerRadius: 16))
            }
            .buttonStyle(.plain).disabled(isProcessing)

            heading("风格预设", subtitle: "一键应用不同影调")
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 9) {
                ForEach(DemoPhotoPreset.allCases.filter { $0 != .custom }) { preset in
                    Button { applyPreset(preset) } label: {
                        HStack(spacing: 9) {
                            Image(systemName: preset.icon).font(.system(size: 17))
                                .foregroundStyle(preset.tint).frame(width: 34, height: 34)
                                .background(preset.tint.opacity(0.13), in: RoundedRectangle(cornerRadius: 10))
                            VStack(alignment: .leading, spacing: 3) {
                                Text(preset.title).font(.system(size: 12, weight: .semibold))
                                Text(preset.subtitle).font(.system(size: 9)).foregroundStyle(.secondary)
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
                    .buttonStyle(.plain)
                }
            }

            heading("AI 实验室", subtitle: "高级智能修复能力，后续版本开放")
            VStack(spacing: 0) {
                placeholder("AI 人像修复", detail: "面部细节与肤质优化", icon: "face.smiling")
                Divider().padding(.leading, 48)
                placeholder("智能去噪", detail: "降低高 ISO 颗粒与噪点", icon: "circle.lefthalf.filled")
                Divider().padding(.leading, 48)
                placeholder("运动去模糊", detail: "恢复运动场景清晰度", icon: "viewfinder")
                Divider().padding(.leading, 48)
                placeholder("老照片修复", detail: "划痕修复与褪色还原", icon: "clock.arrow.circlepath")
            }
            .padding(.horizontal, 13)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 15))
        }
    }

    private var adjustmentPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            heading("精细调整", subtitle: "拖动滑块实时查看画面变化")
            VStack(spacing: 17) {
                slider("曝光", icon: "sun.max", keyPath: \.exposure, range: -2...2, display: signed(settings.exposure))
                slider("亮度", icon: "sun.min", keyPath: \.brightness, range: -0.5...0.5, display: signed(settings.brightness))
                slider("对比度", icon: "circle.lefthalf.filled", keyPath: \.contrast, range: 0.5...1.8, display: decimal(settings.contrast))
                slider("饱和度", icon: "drop", keyPath: \.saturation, range: 0...2, display: decimal(settings.saturation))
                slider("色温", icon: "thermometer.medium", keyPath: \.temperature, range: -100...100, display: signed(settings.temperature))
                slider("高光", icon: "sun.max.fill", keyPath: \.highlights, range: -1...1, display: signed(settings.highlights))
                slider("阴影", icon: "moon", keyPath: \.shadows, range: -1...1, display: signed(settings.shadows))
                slider("锐度", icon: "viewfinder", keyPath: \.sharpness, range: 0...2, display: decimal(settings.sharpness))
            }
            .padding(15)
            .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 17))
            Button("恢复默认参数") { applySettings(DemoAdjustmentSettings(), preset: .original) }
                .font(.system(size: 12, weight: .semibold)).foregroundStyle(accent)
                .frame(maxWidth: .infinity)
        }
    }

    private var comparePanel: some View {
        VStack(alignment: .leading, spacing: 13) {
            heading("前后对比", subtitle: "拖动预览中的分割线查看增强前后差异")
            HStack(spacing: 9) {
                infoCard("原始照片", detail: "保留导入版本", icon: "photo")
                infoCard("编辑结果", detail: "当前调整效果", icon: "sparkles")
            }
            Text("在上方预览区选择「对比」，左右拖动分割线即可查看差异。")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .padding(13).frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
            Button { compareMode = .compare } label: {
                Label("开启滑动对比", systemImage: "arrow.left.and.right")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(13)
                    .background(accent.opacity(0.16), in: RoundedRectangle(cornerRadius: 12))
            }.buttonStyle(.plain)
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
                    .font(.system(size: 13, weight: .bold)).frame(maxWidth: .infinity).padding(14)
                    .background(accent, in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(.black.opacity(0.85))
            }.disabled(isSaving)
            Button { showShareSheet = true } label: {
                Label("分享作品", systemImage: "square.and.arrow.up")
                    .font(.system(size: 13, weight: .semibold)).frame(maxWidth: .infinity).padding(13)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
            }
        }
    }

    private var bottomBar: some View {
        HStack(spacing: 11) {
            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label(originalImage == nil ? "导入照片" : "更换照片", systemImage: "photo.badge.plus")
                    .font(.system(size: 12, weight: .semibold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                    .background(Color(uiColor: .secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 13))
            }
            Button { saveToPhotos() } label: {
                HStack(spacing: 7) {
                    if isSaving { ProgressView().tint(.black) }
                    else { Image(systemName: "square.and.arrow.down") }
                    Text("保存")
                }
                .font(.system(size: 12, weight: .bold)).frame(maxWidth: .infinity).padding(.vertical, 13)
                .background(accent, in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(.black.opacity(0.85))
            }.disabled(originalImage == nil || isSaving)
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 9).background(.bar)
    }

    private func previewModeButton(_ title: String, mode: PreviewMode, icon: String) -> some View {
        Button { compareMode = mode } label: {
            Label(title, systemImage: icon).font(.system(size: 10, weight: .semibold))
                .padding(.horizontal, 10).padding(.vertical, 8)
                .foregroundStyle(compareMode == mode ? Color.primary : Color.secondary)
                .background(compareMode == mode ? Color(uiColor: .tertiarySystemFill) : .clear, in: Capsule())
        }.buttonStyle(.plain)
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
                set: { settings[keyPath: keyPath] = $0; autoEnhanceEnabled = false; selectedPreset = .custom; scheduleRender() }
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

    private func scheduleRender() {
        guard let originalImage else { return }
        let token = UUID()
        renderToken = token
        isProcessing = true
        let currentSettings = settings
        let useAutoEnhance = autoEnhanceEnabled
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                DemoImageProcessor.render(originalImage, settings: currentSettings, autoEnhance: useAutoEnhance)
            }.value
            guard renderToken == token else { return }
            editedImage = result ?? originalImage
            isProcessing = false
        }
    }

    private func saveToPhotos() {
        guard let image = editedImage ?? originalImage, let cgImage = image.cgImage else { return }
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
