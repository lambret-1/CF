import SwiftUI
import PhotosUI
import CoreImage
import ImageIO
import UIKit

struct DemoPhotoAutoEnhanceView: View {
    @State private var pickerItem: PhotosPickerItem?
    @State private var originalImage: UIImage?
    @State private var enhancedImage: UIImage?
    @State private var status = "请选择一张照片"
    @State private var isProcessing = false

    private let context = CIContext(options: [.useSoftwareRenderer: false])

    var body: some View {
        VStack(spacing: 16) {
            HStack(spacing: 12) {
                imagePreview(originalImage, title: "原图")
                imagePreview(enhancedImage, title: "自动调整")
            }
            .frame(maxHeight: .infinity)

            Text(status)
                .font(.subheadline)
                .foregroundStyle(AppTheme.secondaryText)
                .multilineTextAlignment(.center)

            PhotosPicker(selection: $pickerItem, matching: .images) {
                Label("选择照片", systemImage: "photo")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)

            Button(action: processImage) {
                Label(isProcessing ? "正在处理…" : "✨ 一键原生自动调整", systemImage: "wand.and.stars")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(originalImage == nil || isProcessing)
        }
        .padding(DesignTokens.pageMargin)
        .background(AppTheme.background)
        .navigationTitle("Demo")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task {
                do {
                    guard let data = try await item.loadTransferable(type: Data.self),
                          let image = UIImage(data: data) else {
                        status = "无法读取所选照片"
                        return
                    }
                    originalImage = image
                    enhancedImage = nil
                    status = "已载入照片，点击按钮开始自动调整"
                } catch {
                    status = "读取照片失败：\(error.localizedDescription)"
                }
            }
        }
    }

    @ViewBuilder
    private func imagePreview(_ image: UIImage?, title: String) -> some View {
        VStack(spacing: 8) {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(AppTheme.secondaryText)
            ZStack {
                RoundedRectangle(cornerRadius: 12)
                    .fill(AppTheme.previewBackground)
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .padding(6)
                } else {
                    Image(systemName: "photo")
                        .font(.system(size: 28))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func processImage() {
        guard let image = originalImage else { return }
        isProcessing = true
        status = "正在进行原生自动调整…"

        DispatchQueue.global(qos: .userInitiated).async {
            let result = autoEnhanced(image)
            Task { @MainActor in
                enhancedImage = result
                status = result == nil ? "自动调整失败，请换一张照片重试" : "处理完成"
                isProcessing = false
            }
        }
    }

    private func autoEnhanced(_ image: UIImage) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }
        var ciImage = CIImage(cgImage: cgImage)
        let options: [CIImageAutoAdjustmentOption: Any] = [
            .imageOrientation: image.imageOrientation.cgImagePropertyOrientation,
            .crop: false
        ]

        for filter in ciImage.autoAdjustmentFilters(options: options) {
            filter.setValue(ciImage, forKey: kCIInputImageKey)
            if let output = filter.outputImage {
                ciImage = output
            }
        }

        guard let output = context.createCGImage(ciImage, from: ciImage.extent) else {
            return nil
        }
        return UIImage(cgImage: output, scale: image.scale, orientation: image.imageOrientation)
    }
}

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: return .up
        case .down: return .down
        case .left: return .left
        case .right: return .right
        case .upMirrored: return .upMirrored
        case .downMirrored: return .downMirrored
        case .leftMirrored: return .leftMirrored
        case .rightMirrored: return .rightMirrored
        @unknown default: return .up
        }
    }
}
