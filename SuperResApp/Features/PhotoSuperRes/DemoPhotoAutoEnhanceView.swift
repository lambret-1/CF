import SwiftUI
import PhotosUI
import UIKit
import ActivityKit
import Photos

struct DemoPhotoAutoEnhanceView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var selectedAsset: PHAsset?
    @State private var editingInput: PHContentEditingInput?
    @State private var originalImage: UIImage?
    @State private var editedImage: UIImage?
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
            guard let item, originalImage != nil else { return }
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
        .onDisappear {
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
                Button("重置所有调整", systemImage: "arrow.counterclockwise") { resetEdits() }
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
                            .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 10)
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
                HStack(spacing: 30) {
                    cropTool("还原", icon: "crop", action: .reset)
                    cropTool("旋转", icon: "rotate.right", action: .rotate)
                    cropTool("翻转", icon: "arrow.left.and.right.righttriangle.left.righttriangle.right", action: .flip)
                    cropTool(imageTransform.usesSquareCrop ? "原比例" : "正方形", icon: "aspectratio", action: .toggleSquare)
                }
                .frame(height: 78)
            } else {
                HStack(spacing: 18) {
                    Image(systemName: activeTab.icon).font(.system(size: 26))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(activeTab.title).font(.system(size: 14, weight: .semibold))
                        Text("功能入口已预留，后续可直接扩展")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(.horizontal, 24)
                .frame(height: 104)
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

    private func cropTool(_ title: String, icon: String, action: CropAction) -> some View {
        Button {
            var next = imageTransform
            switch action {
            case .reset: next = .identity
            case .rotate: next.quarterTurnsClockwise = (next.quarterTurnsClockwise + 1) % 4
            case .flip: next.isHorizontallyFlipped.toggle()
            case .toggleSquare: next.usesSquareCrop.toggle()
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
                set: {
                    settings[keyPath: keyPath] = $0
                    selectedPreset = .custom
                    autoEnhanceEnabled = false
                    autoEnhanceBaseSettings = nil
                    autoEnhanceBasePreset = nil
                    scheduleRender(debounced: true)
                }
            ), in: range, onEditingChanged: { editing in
                if editing {
                    editingSnapshot = captureSnapshot()
                } else if let snapshot = editingSnapshot {
                    if snapshot != captureSnapshot() {
                        undoStack.append(snapshot)
                        redoStack.removeAll()
                    }
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

    private var hasChanges: Bool {
        originalImage != nil && (settings != DemoAdjustmentSettings() || autoEnhanceEnabled || selectedPreset.filterName != nil || imageTransform != .identity)
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

            if let identifier = item.itemIdentifier {
                do {
                    let asset = try await PhotoKitEditingService.shared.fetchAsset(localIdentifier: identifier)
                    let input = try await PhotoKitEditingService.shared.requestEditingInput(for: asset)
                    loadedImage = try await PhotoKitEditingService.shared.originalImage(from: input)
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
            renderToken = UUID()
            selectedAsset = loadedAsset
            editingInput = loadedInput
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
            imageTransform: imageTransform
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
            imageTransform: imageTransform
        )
    }

    private func restoreSnapshot(_ snapshot: DemoEditorSnapshot) {
        settings = snapshot.settings
        selectedPreset = snapshot.selectedPreset
        autoEnhanceEnabled = snapshot.autoEnhanceEnabled
        autoEnhanceBaseSettings = snapshot.autoEnhanceBaseSettings
        autoEnhanceBasePreset = snapshot.autoEnhanceBasePreset
        imageTransform = snapshot.imageTransform
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
            imageTransform: .identity
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
        if currentSettings == DemoAdjustmentSettings() && !useAutoEnhance && currentFilterName == nil && currentTransform == .identity {
            editedImage = originalImage
            isProcessing = false
            return
        }
        Task {
            if debounced { try? await Task.sleep(for: .milliseconds(100)) }
            guard renderToken == token else { return }
            let result = await Task.detached(priority: .userInitiated) {
                DemoImageProcessor.render(originalImage, settings: currentSettings, autoEnhance: useAutoEnhance, filterName: currentFilterName, transform: currentTransform)
            }.value
            guard renderToken == token else { return }
            editedImage = result ?? originalImage
            isProcessing = false
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
                            "saturation": settings.saturation
                        ],
                        "preset": selectedPreset.rawValue,
                        "autoEnhance": autoEnhanceEnabled,
                        "rotation": imageTransform.quarterTurnsClockwise,
                        "horizontalFlip": imageTransform.isHorizontallyFlipped,
                        "squareCrop": imageTransform.usesSquareCrop
                    ]
                    let data = try JSONSerialization.data(withJSONObject: adjustment, options: [.sortedKeys])
                    try await PhotoKitEditingService.shared.saveRenderedImage(
                        cgImage,
                        asset: asset,
                        input: input,
                        adjustmentData: data
                    )
                    alertMessage = "已将编辑作为非破坏性修改保存到原照片。"
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
}

private enum CropAction { case reset, rotate, flip, toggleSquare }

private enum PreviewMode { case result, original }

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
        case .saturation: "drop.fill"
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
