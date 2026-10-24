import SwiftUI
import PhotosUI

struct PhotoRestoreView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var restoredImage: UIImage?
    @State private var isProcessing = false
    
    private let colorEngine = TrueColorEngine()
    
    var body: some View {
        VStack(spacing: 0) {
            // 预览区
            GeometryReader { geo in
                ZStack {
                    Color.black.opacity(0.9)
                    
                    if let displayImage = restoredImage ?? originalImage {
                        Image(uiImage: displayImage)
                            .resizable()
                            .scaledToFit()
                            .frame(width: geo.size.width, height: geo.size.height)
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
                            .tint(.white)
                            .foregroundColor(.white)
                    }
                }
            }
            
            // 底部操作区
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
                    Button {
                        processImage()
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
                }
            }
            .padding()
            .background(Color(uiColor: .systemBackground))
        }
        .navigationTitle("真实色彩还原")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                if let data = try? await newItem.loadTransferable(type: Data.self),
                   let uiImage = UIImage(data: data) {
                    await MainActor.run {
                        self.originalImage = uiImage
                        self.restoredImage = nil // 选新图时清空上次的结果
                        self.pickerItem = nil
                    }
                }
            }
        }
    }
    
    private func processImage() {
        guard let original = originalImage else { return }
        isProcessing = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = colorEngine.restoreTrueColor(image: original)
            DispatchQueue.main.async {
                self.restoredImage = result
                self.isProcessing = false
            }
        }
    }
}