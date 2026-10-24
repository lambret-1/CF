import SwiftUI
import PhotosUI
import CoreLocation

struct PhotoRestoreView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var restoredImage: UIImage?
    @State private var isProcessing = false
    
    private let restorer = TrueColorEngine()
    
    var body: some View {
        VStack(spacing: 20) {
            ZStack {
                Color.black.opacity(0.9)
                if let displayImage = restoredImage ?? originalImage {
                    Image(uiImage: displayImage)
                        .resizable()
                        .scaledToFit()
                } else {
                    Text("请选择照片").foregroundColor(.gray)
                }
                
                if isProcessing {
                    ProgressView().tint(.white)
                }
            }
            .frame(maxHeight: 400)
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .padding()
            
            Spacer()
            
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
                    Button("一键还原真实色彩") {
                        processImage()
                    }
                    .font(.headline)
                    .foregroundColor(.white)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.green)
                    .cornerRadius(10)
                    .disabled(isProcessing)
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 30)
        }
        .navigationTitle("照片色彩还原")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem = newItem else { return }
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
    
    private func processImage() {
        guard let original = originalImage else { return }
        isProcessing = true
        
        DispatchQueue.global(qos: .userInitiated).async {
            let result = restorer.restoreTrueColor(image: original, captureDate: Date(), location: nil)
            
            DispatchQueue.main.async {
                self.restoredImage = result
                self.isProcessing = false
            }
        }
    }
}