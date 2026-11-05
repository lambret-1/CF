import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

extension DemoPhotoAutoEnhanceView {
func revertPhotoToOriginal() {
        guard let asset = selectedAsset else { return }
        isSaving = true
        Task {
            do {
                try await PhotoKitEditingService.shared.revertToOriginal(asset: asset)
                let refreshedAsset = try await PhotoKitEditingService.shared.fetchAsset(localIdentifier: asset.localIdentifier)
                let refreshedInput = try await PhotoKitEditingService.shared.requestEditingInput(for: refreshedAsset)
                let image = try await PhotoKitEditingService.shared.originalImage(from: refreshedInput)
                selectedAsset = refreshedAsset
                editingInput = refreshedInput
                renderSourceURL = refreshedInput.fullSizeImageURL
                usesRAWResource = refreshedInput.uniformTypeIdentifier.flatMap { UTType($0) }?.conforms(to: .rawImage) == true
                originalImage = image
                editedImage = image
                settings = DemoAdjustmentSettings()
                selectedPreset = .original
                autoEnhanceEnabled = false
                autoEnhanceBaseSettings = nil
                autoEnhanceBasePreset = nil
                imageTransform = .identity
                markupData = nil
                undoStack.removeAll()
                redoStack.removeAll()
                analysisResult = nil
                compareMode = .result
                scheduleRender()
                alertMessage = "已通过 PhotoKit 恢复照片原始版本。"
            } catch {
                alertMessage = error.localizedDescription
            }
            isSaving = false
        }
    }

    func saveToPhotos() {
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
                            "saturation": settings.saturation,
                            "vibrance": settings.vibrance,
                            "highlights": settings.highlights,
                            "shadows": settings.shadows,
                            "temperature": settings.temperature,
                            "tint": settings.tint,
                            "sharpness": settings.sharpness,
                            "noiseReduction": settings.noiseReduction,
                            "vignette": settings.vignette
                        ],
                        "markupData": markupData?.base64EncodedString() ?? "",
                        "preset": selectedPreset.rawValue,
                        "autoEnhance": autoEnhanceEnabled,
                        "autoEnhanceBaseSettings": autoEnhanceBaseSettings.map { [
                            "exposure": $0.exposure, "brightness": $0.brightness,
                            "contrast": $0.contrast, "saturation": $0.saturation,
                            "vibrance": $0.vibrance, "highlights": $0.highlights,
                            "shadows": $0.shadows, "temperature": $0.temperature,
                            "tint": $0.tint, "sharpness": $0.sharpness,
                            "noiseReduction": $0.noiseReduction, "vignette": $0.vignette
                        ] } ?? [:],
                        "autoEnhanceBasePreset": autoEnhanceBasePreset?.rawValue ?? "",
                        "rotation": imageTransform.quarterTurnsClockwise,
                        "horizontalFlip": imageTransform.isHorizontallyFlipped,
                        "squareCrop": imageTransform.usesSquareCrop,
                        "straightenAngle": imageTransform.straightenAngle,
                        "perspectiveCorrection": imageTransform.usesPerspectiveCorrection,
                        "depthBlur": imageTransform.usesDepthBlur,
                        "usesRAW": usesRAWResource,
                        "cropAspectRatio": imageTransform.cropAspectRatio ?? 0,
                        "cropRect": imageTransform.cropRect.map { [$0.origin.x, $0.origin.y, $0.size.width, $0.size.height] } ?? []
                    ]
                    let data = try JSONSerialization.data(withJSONObject: adjustment, options: [.sortedKeys])
                    if asset.mediaSubtypes.contains(.photoLive), input.livePhoto != nil {
                        try await PhotoKitEditingService.shared.saveLivePhoto(
                            asset: asset,
                            input: input,
                            settings: settings,
                            filterName: selectedPreset.filterName,
                            autoEnhance: autoEnhanceEnabled,
                            transform: imageTransform,
                            adjustmentData: data,
                            markupData: markupData,
                            markupSize: originalImage?.size ?? image.size,
                            markupScale: originalImage?.scale ?? image.scale
                        )
                        alertMessage = "Live Photo 的照片帧与动态视频帧已作为非破坏性修改保存。"
                    } else {
                        if let renderedCIImage {
                            try await PhotoKitEditingService.shared.saveRenderedCIImage(
                                renderedCIImage,
                                asset: asset,
                                input: input,
                                adjustmentData: data,
                                isHDR: usesRAWResource || ((renderSourceURL ?? input.fullSizeImageURL).map {
                                    ApplePhotoAnalysisService.containsHDRGainMap(at: $0)
                                } ?? false)
                            )
                        } else {
                            try await PhotoKitEditingService.shared.saveRenderedImage(
                                cgImage,
                                asset: asset,
                                input: input,
                                adjustmentData: data
                            )
                        }
                        alertMessage = "已将编辑作为 10-bit HEIF 非破坏性修改保存到原照片。"
                    }
                } else {
                    try await PhotoLibraryService.shared.save(cgImage)
                    alertMessage = "照片已另存到系统相册。"
                }
                if let asset = selectedAsset {
                    do {
                        let refreshed = try await PhotoKitEditingService.shared.fetchAsset(localIdentifier: asset.localIdentifier)
                        let refreshedInput = try await PhotoKitEditingService.shared.requestEditingInput(for: refreshed)
                        selectedAsset = refreshed
                        editingInput = refreshedInput
                        if !usesRAWResource {
                            renderSourceURL = refreshedInput.fullSizeImageURL
                        }
                    } catch {
                        // Keep the successful save result if a fresh editing input cannot be acquired.
                    }
                }
                await endLiveActivity()
            } catch {
                alertMessage = error.localizedDescription
            }
            isSaving = false
        }
    }
}
