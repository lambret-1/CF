import SwiftUI
import PhotosUI
import Photos

struct PhotoRestoreView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var restoredImage: UIImage?
    
    @State private var isProcessing = false
    @State private var isShowingOriginal = false // 用于长按对比
    @State private var intensity: CGFloat = 1.0  // 还原强度
    @State private var alertMessage: String?
    
    private let colorEngine = TrueColorEngine()
    
    var body: some View {
        VStack(spacing: 0) {
            // 1. 预览区
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.9)
                    
                    // 核心逻辑：如果正在长按，显示原图；否则如果有结果就显示结果，没结果显示原图
                    if let display)
Image = isShowingOriginal ? originalImage : (restoredImage ?? originalImage) {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
                            // ⭐️ 关键：手指按下与松开的手势
                            .onLongPressGesture(minimumDuration: .infinity, pressing: { pressing in
                                withAnimation(.easeInOut(duration: 0.1)) {
                                    self.isShowingOriginal = pressing
                                }
                            }, perform: {})
                    } else {
                        VStack(spacing: 12) {
                            Image(systemName: "paintpalette")
                                .font(.system(size: 50))
                                .foregroundColor(.gray)
                            Text("请选择需要还原色彩的照片")
                                .foregroundColor(.gray)
                        }
                    }
                    
                    if isProcessing {
                        Color.black.opacity(0.5)
                        ProgressView("正在分析色彩...")
                            .tint(.white                            .foregroundColor(.white)
                    }
                    
                    // 长按提示
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
            
            // 2. 控制面板 (有还原结果时才显示)
            if restoredImage != nil {
                VStack(spacing: 12) {
                    HStack {
                        Text("还原强度")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        Slider(value: $intensity, in: 0...1, onEditingChanged: { editing in
                            if !editing {
                                processImage() // 拖动结束时重新计算
                            }
                        })
                        Text("\(Int(intensity * 100))%")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .frame(width: 35, alignment: .trailing)
                    }
                    .padding(.horizontal)
                }
                .padding(.vertical, 12)
                .background(Color(uiColor: .secondarySystemBackground))
            }
            
            // 3. 底部操作区
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
                            processImage()
                        } label: {
                            HStack {
                                Image(systemName: "wand.and.stars")
                                Text("一键还原")
                            }
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(10)
                        }
                        .disabled(isProcessing)
                        
                        // ⭐️ 新增：保存按钮
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
                        self.intensity = 1.0
                        self.pickerItem = nil
                    }
                }
            }
        }
    }
    
    // MARK: - 执行色彩还原
    private func processImage() {
        guard let original = originalImage else { return }
        isProcessing = true
        
        let currentIntensity = intensity
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = colorEngine.restoreTrueColor(image: original, intensity: currentIntensity)
            DispatchQueue.main.async {
                self.restoredImage = result
                self.isProcessing = false
            }
        }
    }
    
    // MARK: - 保存到相册
    private func saveToAlbum(image: UIImage) {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async {
                    self.alertMessage = "未获得相册权限，请在设置中开启"
                }
                return
            }
            
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: image)
            } completionHandler: { success, error in
                DispatchQueue.main.async {
                    if success {
                        self.alertMessage = "✅ 照片已保存到相册"
                    } else {
                        self.alertMessage = "保存失败：\(error?.localizedDescription ?? "未知错误")"
                    }
                }
            }
        }
    }
}