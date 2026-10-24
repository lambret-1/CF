import SwiftUI
import PhotosUI
import Photos

struct PhotoRestoreView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var restoredImage: UIImage?
    
    @State private var isProcessing = false
    @State private var isShowingOriginal = false
    @State private var alertMessage: String?
    
    // ⭐️ 核心对齐：实例化 PhotoColorRestorer（因为 init?() 是可选类型）
    private let colorEngine = PhotoColorRestorer()
    
    var body: some View {
        VStack(spacing: 0) {
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.9)
                    
                    if let displayImage = isShowingOriginal ? originalImage : (restoredImage ?? originalImage) {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    self.isShowingOriginal = pressing
                                }
                            }, perform: {})
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)
                            Text("请选择照片")
                                .foregroundColor(.gray)
                        }
                    }
                    
                    if isProcessing {
                        Color.black.opacity(0.5)
                        ProgressView("正在分析光源...")
                            .tint(.white)
                            .foregroundColor(.white)
                    }
                    
                    if restoredImage != nil && !isShowingOriginal && !isProcessing {
                        VStack {
                            Spacer()
                            Text("长按图片查看原图")
                                .font(.caption)
                                .foregroundColor(.white.opacity(0.8))
                                .padding(8)
                                .background(Color.black.opacity(0.5))
                                .cornerRadius(8)
                                .padding(.bottom, 20)
                        }
                    }
                }
            }
            
            VStack(spacing: 16) {
                PhotosPicker(selection: $pickerItem, matching: .images) {
                    Text("从相册选择照片")
                        .font(.headline)
                        .foregroundColor(.white)
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.blue)
                        .cornerRadius(10)
                }
                
                if originalImage != nil {
                    HStack(spacing: 12) {
                        Button {
                            performAutoRestore()
                        } label: {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("一键还原真实色彩")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(10)
                        }
                        .disabled(isProcessing)
                        
                        if let result = restoredImage {
                            Button {
                                saveToAlbum(image: result)
                            } label: {
                                Image(systemName: "square.and.arrow.down")
                                    .font(.headline)
                                    .foregroundColor(.white)
                                    .frame(width: 50, height: 50)
                                    .background(Color.orange)
                                    .cornerRadius(10)
                            }
                        }
                    }
                }
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
        }
        .navigationTitle("真实色彩还原")
        .navigationBarTitleDisplayMode(.inline)
        .alert("提示", isPresented: .init(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )) {
            Button("好的", role: .cancel) { }
        } message: {
            Text(alertMessage ?? "")
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        self.originalImage = uiImage
                        self.restoredImage = nil
                        self.pickerItem = nil
                    }
                }
            }
        }
    }
    
    private func performAutoRestore() {
        guard let original = originalImage else { return }
        isProcessing = true
        AppLogger.shared.log("[PhotoRestoreView] 开始处理图片，尺寸: \(Int(original.size.width))x\(Int(original.size.height))", isError: false)
        
        DispatchQueue.global(qos: .userInitiated).async {
            // ✅ 修复：安全解包 colorEngine，防止 init?() 返回 nil
            guard let engine = self.colorEngine else {
                DispatchQueue.main.async {
                    AppLogger.shared.log("[PhotoRestoreView] ❌ PhotoColorRestorer 初始化失败（色彩空间不可用）", isError: true)
                    self.alertMessage = "色彩引擎初始化失败"
                    self.isProcessing = false
                }
                return
            }
            
            // ✅ 修复：安全解包返回结果
            guard let result = engine.autoRestoreColor(image: original) else {
                DispatchQueue.main.async {
                    AppLogger.shared.log("[PhotoRestoreView] ❌ 色彩还原返回 nil（可能是尺寸太小或计算异常）", isError: true)
                    self.alertMessage = "色彩还原失败，请尝试更换图片"
                    self.isProcessing = false
                }
                return
            }
            
            // 成功拿到结果，切回主线程更新 UI
            DispatchQueue.main.async {
                AppLogger.shared.log("[PhotoRestoreView] ✅ 色彩还原成功，准备更新 UI", isError: false)
                self.restoredImage = result
                self.isProcessing = false
            }
        }
    }
    
    private func saveToAlbum(image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { self.alertMessage = "未获得相册权限" }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    self.alertMessage = success ? "✅ 照片已保存" : "保存失败"
                }
            }
        }
    }
}