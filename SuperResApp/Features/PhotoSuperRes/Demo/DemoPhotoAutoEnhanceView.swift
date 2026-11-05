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

    var body: some View {
        GeometryReader { geometry in
            let safeTop = geometry.safeAreaInsets.top

            VStack(spacing: 0) {
                navigationBar(safeTop: safeTop)
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
        // Expand the GeometryReader's actual hit-testing bounds into the top safe area.
        // The editor controls are rendered there, so their parent must own that area too.
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
                if isCompleteEnabled {
                    saveToPhotos()
                } else {
                    alertMessage = isProcessing ? "正在处理，请稍候。" : "没有可保存的修改。"
                }
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
            loadTask?.cancel()
            renderTask?.cancel()
            cleanupTemporaryRAWResource()
            Task { await endLiveActivity() }
        }
    }
}
