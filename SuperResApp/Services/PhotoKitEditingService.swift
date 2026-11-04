import Foundation
import Photos
import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UniformTypeIdentifiers
import UIKit
import UniformTypeIdentifiers

/// PhotoKit-backed editing for existing library assets.
/// Edits are committed through PHContentEditingOutput so the original resource remains recoverable.
actor PhotoKitEditingService {
    static let shared = PhotoKitEditingService()

    private let adjustmentFormatIdentifier = "com.superres.app.photo-editor"
    private let adjustmentFormatVersion = "1.0"

    private init() {}

    func requestReadWriteAuthorization() async -> PHAuthorizationStatus {
        let current = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard current == .notDetermined else { return current }
        return await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { status in
                continuation.resume(returning: status)
            }
        }
    }

    func fetchAsset(localIdentifier: String) async throws -> PHAsset {
        let status = await requestReadWriteAuthorization()
        guard status == .authorized || status == .limited else {
            throw PhotoKitEditingError.authorizationDenied
        }
        let result = PHAsset.fetchAssets(withLocalIdentifiers: [localIdentifier], options: nil)
        guard let asset = result.firstObject else {
            throw PhotoKitEditingError.assetUnavailable
        }
        return asset
    }

    func requestEditingInput(for asset: PHAsset) async throws -> PHContentEditingInput {
        try await withCheckedThrowingContinuation { continuation in
            let options = PHContentEditingInputRequestOptions()
            options.isNetworkAccessAllowed = true
            asset.requestContentEditingInput(with: options) { input, info in
                if let input {
                    continuation.resume(returning: input)
                } else if (info[PHContentEditingInputCancelledKey] as? Bool) == true {
                    continuation.resume(throwing: CancellationError())
                } else {
                    continuation.resume(throwing: PhotoKitEditingError.editingInputUnavailable)
                }
            }
        }
    }

    func originalImage(from input: PHContentEditingInput) throws -> UIImage {
        guard let url = input.fullSizeImageURL else {
            throw PhotoKitEditingError.originalImageUnavailable
        }
        if let identifier = input.uniformTypeIdentifier,
           let type = UTType(identifier),
           type.conforms(to: .rawImage) {
            return try ApplePhotoAnalysisService.renderRawImage(at: url)
        }
        guard let image = UIImage(contentsOfFile: url.path) else {
            throw PhotoKitEditingError.originalImageUnavailable
        }
        return image
    }

    func resourceTypes(for asset: PHAsset) -> [PHAssetResourceType] {
        PHAssetResource.assetResources(for: asset).map(\.type)
    }

    func saveRenderedImage(
        _ image: CGImage,
        asset: PHAsset,
        input: PHContentEditingInput,
        adjustmentData: Data
    ) async throws {
        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: adjustmentFormatIdentifier,
            formatVersion: adjustmentFormatVersion,
            data: adjustmentData
        )

        let destinationType: UTType = {
            if let identifier = input.uniformTypeIdentifier,
               let type = UTType(identifier),
               type.conforms(to: .image),
               !type.conforms(to: .rawImage) {
                return type
            }
            return .jpeg
        }()

        guard let destination = CGImageDestinationCreateWithURL(
            output.renderedContentURL as CFURL,
            destinationType.identifier as CFString,
            1,
            nil
        ) else {
            throw PhotoKitEditingError.renderedOutputUnavailable
        }

        var properties: [CFString: Any] = [:]
        if let sourceURL = input.fullSizeImageURL,
           let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
           let sourceProperties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] {
            properties = sourceProperties
        }
        properties[kCGImagePropertyOrientation] = 1
        CGImageDestinationAddImage(destination, image, properties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw PhotoKitEditingError.outputWriteFailed
        }

        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).contentEditingOutput = output
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoKitEditingError.saveFailed)
                }
            }
        }
    }

    func saveLivePhoto(
        asset: PHAsset,
        input: PHContentEditingInput,
        settings: DemoAdjustmentSettings,
        filterName: String?,
        autoEnhance: Bool,
        transform: DemoImageTransform,
        adjustmentData: Data
    ) async throws {
        guard input.livePhoto != nil,
              let editingContext = PHLivePhotoEditingContext(livePhotoEditingInput: input) else {
            throw PhotoKitEditingError.livePhotoUnavailable
        }

        editingContext.frameProcessor = { frame, _ in
            var output = frame.image
            if autoEnhance {
                for filter in output.autoAdjustmentFilters(options: [:]) {
                    filter.setValue(output, forKey: kCIInputImageKey)
                    if let next = filter.outputImage { output = next }
                }
            } else if let filterName, let filter = CIFilter(name: filterName) {
                filter.setValue(output, forKey: kCIInputImageKey)
                if let next = filter.outputImage { output = next }
            }

            if abs(settings.exposure) > 0.0001 {
                let filter = CIFilter.exposureAdjust()
                filter.inputImage = output
                filter.ev = Float(settings.exposure)
                if let next = filter.outputImage { output = next }
            }
            if abs(settings.brightness) > 0.0001 ||
                abs(settings.contrast - 1) > 0.0001 ||
                abs(settings.saturation - 1) > 0.0001 {
                let filter = CIFilter.colorControls()
                filter.inputImage = output
                filter.brightness = Float(settings.brightness)
                filter.contrast = Float(settings.contrast)
                filter.saturation = Float(settings.saturation)
                if let next = filter.outputImage { output = next }
            }
            if abs(settings.highlights) > 0.0001 || abs(settings.shadows) > 0.0001 {
                let filter = CIFilter(name: "CIHighlightShadowAdjust")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(settings.highlights, forKey: "inputHighlightAmount")
                filter?.setValue(settings.shadows, forKey: "inputShadowAmount")
                if let next = filter?.outputImage { output = next }
            }
            if abs(settings.temperature - 6500) > 0.5 || abs(settings.tint) > 0.0001 {
                let filter = CIFilter(name: "CITemperatureAndTint")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
                filter?.setValue(CIVector(x: settings.temperature, y: settings.tint), forKey: "inputTargetNeutral")
                if let next = filter?.outputImage { output = next }
            }
            if abs(settings.sharpness) > 0.0001 {
                let filter = CIFilter(name: "CISharpenLuminance")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(settings.sharpness, forKey: "inputSharpness")
                if let next = filter?.outputImage { output = next }
            }
            if abs(settings.noiseReduction) > 0.0001 {
                let filter = CIFilter(name: "CINoiseReduction")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(settings.noiseReduction, forKey: "inputNoiseLevel")
                filter?.setValue(0.4, forKey: "inputSharpness")
                if let next = filter?.outputImage { output = next }
            }
            if abs(settings.vignette) > 0.0001 {
                let filter = CIFilter(name: "CIVignette")
                filter?.setValue(output, forKey: kCIInputImageKey)
                filter?.setValue(settings.vignette, forKey: "inputIntensity")
                filter?.setValue(max(output.extent.width, output.extent.height) * 0.75, forKey: "inputRadius")
                if let next = filter?.outputImage { output = next }
            }

            let turns = ((transform.quarterTurnsClockwise % 4) + 4) % 4
            switch turns {
            case 1: output = output.oriented(.right)
            case 2: output = output.oriented(.down)
            case 3: output = output.oriented(.left)
            default: break
            }
            if transform.isHorizontallyFlipped {
                output = output.oriented(.upMirrored)
            }
            if transform.usesSquareCrop {
                let bounds = output.extent.integral
                let side = min(bounds.width, bounds.height)
                output = output.cropped(to: CGRect(
                    x: bounds.midX - side / 2,
                    y: bounds.midY - side / 2,
                    width: side,
                    height: side
                ))
            }
            return output
        }

        let output = PHContentEditingOutput(contentEditingInput: input)
        output.adjustmentData = PHAdjustmentData(
            formatIdentifier: adjustmentFormatIdentifier,
            formatVersion: adjustmentFormatVersion,
            data: adjustmentData
        )

        try await withCheckedThrowingContinuation { continuation in
            editingContext.saveLivePhoto(to: output, options: nil) { success, error in
                guard success else {
                    continuation.resume(throwing: error ?? PhotoKitEditingError.livePhotoSaveFailed)
                    return
                }
                PHPhotoLibrary.shared().performChanges {
                    PHAssetChangeRequest(for: asset).contentEditingOutput = output
                } completionHandler: { saved, saveError in
                    if saved {
                        continuation.resume()
                    } else {
                        continuation.resume(throwing: saveError ?? PhotoKitEditingError.saveFailed)
                    }
                }
            }
        }
    }

    func revertToOriginal(asset: PHAsset) async throws {
        try await withCheckedThrowingContinuation { continuation in
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest(for: asset).revertAssetContentToOriginal()
            } completionHandler: { success, error in
                if success {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: error ?? PhotoKitEditingError.revertFailed)
                }
            }
        }
    }

    func originalResources(for asset: PHAsset) -> [PHAssetResource] {
        PHAssetResource.assetResources(for: asset)
    }
}

enum PhotoKitEditingError: LocalizedError {
    case authorizationDenied
    case assetUnavailable
    case editingInputUnavailable
    case originalImageUnavailable
    case renderedOutputUnavailable
    case outputWriteFailed
    case saveFailed
    case revertFailed
    case livePhotoUnavailable
    case livePhotoSaveFailed

    var errorDescription: String? {
        switch self {
        case .authorizationDenied: return "需要允许访问照片图库，才能编辑原照片。"
        case .assetUnavailable: return "所选照片已不可用，请重新选择。"
        case .editingInputUnavailable: return "无法读取照片的编辑输入。"
        case .originalImageUnavailable: return "无法读取照片原始图像。"
        case .renderedOutputUnavailable: return "无法创建 PhotoKit 编辑输出。"
        case .outputWriteFailed: return "写入编辑图像失败。"
        case .saveFailed: return "保存照片编辑失败。"
        case .revertFailed: return "恢复照片原始版本失败。"
        case .livePhotoUnavailable: return "无法创建 Live Photo 编辑会话。"
        case .livePhotoSaveFailed: return "Live Photo 的图像与视频帧处理失败。"
        }
    }
}
