import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

struct DemoPhotoAutoEnhanceView: View {
    @State var pickerItem: PhotosPickerItem?
    @State var selectedAsset: PHAsset?
    @State var editingInput: PHContentEditingInput?
    @State var renderSourceURL: URL?
    @State var usesRAWResource = false
    @State var analysisResult: ApplePhotoAnalysisResult?
    @State var foregroundCutout: UIImage?
    @State var isExtractingSubject = false
    @State var isAnalyzing = false
    @State var isLoadingRAW = false
    @State var showMarkupEditor = false
    @State var showFreeCropEditor = false
    @State var markupData: Data?
    @State var originalImage: UIImage?
    @State var editedImage: UIImage?
    @State var renderedCIImage: CIImage?
    @State var settings = DemoAdjustmentSettings()
    @State var imageTransform = DemoImageTransform.identity
    @State var selectedPreset: DemoPhotoPreset = .original
    @State var activeTab: EditorTab = .adjust
    @State var compareMode: PreviewMode = .result
    @State var autoEnhanceEnabled = false
    @State var autoEnhanceBaseSettings: DemoAdjustmentSettings?
    @State var autoEnhanceBasePreset: DemoPhotoPreset?
    @State var undoStack: [DemoEditorSnapshot] = []
    @State var redoStack: [DemoEditorSnapshot] = []
    @State var editingSnapshot: DemoEditorSnapshot?
    @State var renderToken = UUID()
    @State var photoGeneration = UUID()
    @State var loadTask: Task<Void, Never>?
    @State var renderTask: Task<Void, Never>?
    @State var lastLiveActivityCanComplete: Bool?
    @State var libraryObserverStarted = false
    @State var isProcessing = false
    @State var isSaving = false
    @State var alertMessage: String?
    @State var showShareSheet = false
    @State var selectedAdjustment: AdjustmentControl = .exposure
    @State var liveActivity: Activity<PhotoEditorActivityAttributes>?
    @State var liveActivitySessionID: String?
    @Environment(\.dismiss) var dismiss
    @ObservedObject var libraryObserver = PhotoLibraryChangeObserver.shared
    @Environment(\.scenePhase) var scenePhase

    init(initialPickerItem: PhotosPickerItem? = nil) {
        _pickerItem = State(initialValue: initialPickerItem)
    }

    let accent = Color(red: 0.43, green: 0.78, blue: 0.68)

    /// 真实窗口安全区。GeometryReader 里的 safeAreaInsets 在本视图
    /// 应用 `.ignoresSafeArea(edges: .top)` 后会变成 0，不能用来布局顶栏。
    var windowTopInset: CGFloat {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap { $0.windows }
            .first { $0.isKeyWindow }?
            .safeAreaInsets.top ?? 0
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                navigationBar(topInset: windowTopInset)
                if originalImage != nil { quickToolbar }
                preview
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                if originalImage != nil {
                    parameterPanel
                    editorTabBar
                }
            }
            .frame(
                width: geometry.size.width,
                height: geometry.size.height,
                alignment: .top
            )
            .background(Color(uiColor: .systemBackground).ignoresSafeArea())
        }
        // 背景与预览铺满到屏幕边缘，但顶栏自己按真实安全区下移，
        // 44pt 点击热区完全落在灵动岛/传感器区域下方。
        .ignoresSafeArea(edges: .top)
        .toolbar(.hidden, for: .navigationBar)
        .statusBarHidden(true)
        .task {
            guard let initialItem = pickerItem, originalImage == nil else { return }
            let generation = UUID()
            photoGeneration = generation
            isLoadingRAW = false
            isAnalyzing = false
            isExtractingSubject = false
            loadTask?.cancel()
            let task = Task { await loadPhoto(initialItem, generation: generation) }
            loadTask = task
            await task.value
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            let generation = UUID()
            photoGeneration = generation
            loadTask?.cancel()
            loadTask = Task { await loadPhoto(item, generation: generation) }
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
            case "complete":
                saveToPhotos()
            default: break
            }
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
            guard !libraryObserverStarted else { return }
            libraryObserverStarted = true
            libraryObserver.start()
        }
        .onChange(of: libraryObserver.changeCount) { _, _ in
            refreshSelectedAsset()
        }
        .onDisappear {
            if libraryObserverStarted {
                libraryObserverStarted = false
                libraryObserver.stop()
            }
            photoGeneration = UUID()
            loadTask?.cancel()
            renderTask?.cancel()
            // 保存流程可能仍在使用 CF-RAW- 临时文件，此时不能删。
            if !isSaving {
                cleanupTemporaryRAWResource()
            }
            Task { await endLiveActivity() }
        }
    }
}
