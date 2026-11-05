import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

extension DemoPhotoAutoEnhanceView {
@MainActor
func loadPhoto(_ item: PhotosPickerItem, generation: UUID) async {
        guard generation == photoGeneration else { return }
        isLoadingRAW = false
        isAnalyzing = false
        isExtractingSubject = false
        do {
            var loadedImage: UIImage?
            var loadedAsset: PHAsset?
            var loadedInput: PHContentEditingInput?
            var loadedSourceURL: URL?
            var loadedUsesRAW = false

            if let identifier = item.itemIdentifier {
                do {
                    let asset = try await PhotoKitEditingService.shared.fetchAsset(localIdentifier: identifier)
                    let input = try await PhotoKitEditingService.shared.requestEditingInput(for: asset)
                    let isNativeRAW = input.uniformTypeIdentifier.flatMap { UTType($0) }?.conforms(to: .rawImage) == true
                    let shouldUseRAW = isNativeRAW || adjustmentDataUsesRAW(input.adjustmentData)
                    if shouldUseRAW && !isNativeRAW {
                        do {
                            let rawURL = try await PhotoKitEditingService.shared.rawResourceURL(for: asset)
                            loadedSourceURL = rawURL
                            loadedImage = try await Task.detached(priority: .userInitiated) {
                                try ApplePhotoAnalysisService.renderRawImage(at: rawURL)
                            }.value
                            loadedUsesRAW = true
                        } catch {
                            if let loadedSourceURL, loadedSourceURL.lastPathComponent.hasPrefix("CF-RAW-") {
                                try? FileManager.default.removeItem(at: loadedSourceURL)
                            }
                            loadedImage = try await PhotoKitEditingService.shared.originalImage(from: input)
                            loadedSourceURL = input.fullSizeImageURL
                            loadedUsesRAW = false
                        }
                    } else {
                        loadedImage = try await PhotoKitEditingService.shared.originalImage(from: input)
                        loadedSourceURL = input.fullSizeImageURL
                        loadedUsesRAW = isNativeRAW
                    }
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
            guard !Task.isCancelled, generation == photoGeneration else {
                if let loadedSourceURL, loadedSourceURL.lastPathComponent.hasPrefix("CF-RAW-") {
                    try? FileManager.default.removeItem(at: loadedSourceURL)
                }
                return
            }
            guard let image = loadedImage else {
                self.pickerItem = .none
                alertMessage = "无法读取所选照片，请重新选择。"
                return
            }

            pickerItem = nil
            cleanupTemporaryRAWResource()
            renderTask?.cancel()
            renderToken = UUID()
            renderedCIImage = nil
            selectedAsset = loadedAsset
            editingInput = loadedInput
            renderSourceURL = loadedSourceURL
            usesRAWResource = loadedUsesRAW
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
            analysisResult = nil
            foregroundCutout = nil
            markupData = nil
            restoreAdjustmentData(loadedInput?.adjustmentData)
            scheduleRender()
            await startLiveActivity()
        } catch {
            guard generation == photoGeneration else { return }
            self.pickerItem = .none
            alertMessage = "读取照片失败：\(error.localizedDescription)"
        }
    }


    @MainActor

func adjustmentDataUsesRAW(_ adjustmentData: PHAdjustmentData?) -> Bool {
        guard let adjustmentData,
              let root = try? JSONSerialization.jsonObject(with: adjustmentData.data) as? [String: Any] else {
            return false
        }
        return root["usesRAW"] as? Bool ?? false
    }

    func refreshSelectedAsset() {
        guard let identifier = selectedAsset?.localIdentifier else { return }
        let generation = photoGeneration

        Task {
            guard let refreshed = try? await PhotoKitEditingService.shared.fetchAsset(localIdentifier: identifier),
                  generation == photoGeneration,
                  selectedAsset?.localIdentifier == identifier,
                  let refreshedInput = try? await PhotoKitEditingService.shared.requestEditingInput(for: refreshed),
                  generation == photoGeneration,
                  selectedAsset?.localIdentifier == identifier else {
                return
            }

            selectedAsset = refreshed
            editingInput = refreshedInput
            if !usesRAWResource {
                renderSourceURL = refreshedInput.fullSizeImageURL
            }
        }
    }

    func restoreAdjustmentData(_ adjustmentData: PHAdjustmentData?) {
        guard let adjustmentData,
              adjustmentData.formatIdentifier == "com.superres.app.photo-editor",
              let root = try? JSONSerialization.jsonObject(with: adjustmentData.data) as? [String: Any] else {
            return
        }

        if let values = root["settings"] as? [String: Double] {
            settings.exposure = values["exposure"] ?? 0
            settings.brightness = values["brightness"] ?? 0
            settings.contrast = values["contrast"] ?? 1
            settings.saturation = values["saturation"] ?? 1
            settings.vibrance = values["vibrance"] ?? 0
            settings.highlights = values["highlights"] ?? 0
            settings.shadows = values["shadows"] ?? 0
            settings.temperature = values["temperature"] ?? 6500
            settings.tint = values["tint"] ?? 0
            settings.sharpness = values["sharpness"] ?? 0
            settings.noiseReduction = values["noiseReduction"] ?? 0
            settings.vignette = values["vignette"] ?? 0
        }
        if let rawPreset = root["preset"] as? String,
           let preset = DemoPhotoPreset(rawValue: rawPreset) {
            selectedPreset = preset
        }
        autoEnhanceEnabled = root["autoEnhance"] as? Bool ?? false
        if let base = root["autoEnhanceBaseSettings"] as? [String: Double] {
            autoEnhanceBaseSettings = DemoAdjustmentSettings(
                exposure: base["exposure"] ?? 0,
                brightness: base["brightness"] ?? 0,
                contrast: base["contrast"] ?? 1,
                saturation: base["saturation"] ?? 1,
                vibrance: base["vibrance"] ?? 0,
                highlights: base["highlights"] ?? 0,
                shadows: base["shadows"] ?? 0,
                temperature: base["temperature"] ?? 6500,
                tint: base["tint"] ?? 0,
                sharpness: base["sharpness"] ?? 0,
                noiseReduction: base["noiseReduction"] ?? 0,
                vignette: base["vignette"] ?? 0
            )
        } else if autoEnhanceEnabled {
            autoEnhanceBaseSettings = settings
        }
        if let rawBasePreset = root["autoEnhanceBasePreset"] as? String,
           let basePreset = DemoPhotoPreset(rawValue: rawBasePreset) {
            autoEnhanceBasePreset = basePreset
        } else if autoEnhanceEnabled {
            autoEnhanceBasePreset = .original
        }
        if let transform = root["rotation"] as? Int {
            imageTransform.quarterTurnsClockwise = transform
        }
        imageTransform.isHorizontallyFlipped = root["horizontalFlip"] as? Bool ?? false
        imageTransform.usesSquareCrop = root["squareCrop"] as? Bool ?? false
        imageTransform.straightenAngle = root["straightenAngle"] as? Double ?? 0
        imageTransform.usesPerspectiveCorrection = root["perspectiveCorrection"] as? Bool ?? false
        imageTransform.usesDepthBlur = root["depthBlur"] as? Bool ?? false
        if root["usesRAW"] as? Bool == true,
           renderSourceURL?.lastPathComponent.hasPrefix("CF-RAW-") == true {
            usesRAWResource = true
        }
        let cropRatio = root["cropAspectRatio"] as? Double ?? 0
        imageTransform.cropAspectRatio = cropRatio > 0 ? cropRatio : nil
        if let crop = root["cropRect"] as? [Double], crop.count == 4 {
            imageTransform.cropRect = CGRect(x: crop[0], y: crop[1], width: crop[2], height: crop[3])
        } else {
            imageTransform.cropRect = nil
        }
        if let encodedMarkup = root["markupData"] as? String, !encodedMarkup.isEmpty {
            markupData = Data(base64Encoded: encodedMarkup)
        }
    }

    var hasRAWResource: Bool {
        guard let selectedAsset else { return false }
        return PHAssetResource.assetResources(for: selectedAsset)
            .contains(where: ApplePhotoAnalysisService.isRawResource)
    }

    func cleanupTemporaryRAWResource() {
        guard let url = renderSourceURL,
              url.lastPathComponent.hasPrefix("CF-RAW-") else { return }
        try? FileManager.default.removeItem(at: url)
        renderSourceURL = nil
    }

    func loadRAWOriginal() {
        guard let asset = selectedAsset else { return }
        let identifier = asset.localIdentifier
        let generation = photoGeneration
        isLoadingRAW = true

        Task {
            do {
                let url = try await PhotoKitEditingService.shared.rawResourceURL(for: asset)
                guard generation == photoGeneration,
                      selectedAsset?.localIdentifier == identifier else {
                    if url.lastPathComponent.hasPrefix("CF-RAW-") {
                        try? FileManager.default.removeItem(at: url)
                    }
                    return
                }

                let rawImage = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.renderRawImage(at: url)
                }.value

                guard generation == photoGeneration,
                      selectedAsset?.localIdentifier == identifier else {
                    if url.lastPathComponent.hasPrefix("CF-RAW-") {
                        try? FileManager.default.removeItem(at: url)
                    }
                    return
                }

                let previousSourceURL = renderSourceURL
                if previousSourceURL != url,
                   let previousSourceURL,
                   previousSourceURL.lastPathComponent.hasPrefix("CF-RAW-") {
                    try? FileManager.default.removeItem(at: previousSourceURL)
                }
                undoStack.removeAll()
                redoStack.removeAll()
                renderSourceURL = url
                usesRAWResource = true
                originalImage = rawImage
                editedImage = rawImage
                renderedCIImage = CIImage(image: rawImage)
                settings = DemoAdjustmentSettings()
                selectedPreset = .original
                autoEnhanceEnabled = false
                imageTransform = .identity
                markupData = nil
                analysisResult = nil
                foregroundCutout = nil
                compareMode = .result
                scheduleRender()
            } catch {
                guard generation == photoGeneration,
                      selectedAsset?.localIdentifier == identifier else {
                    return
                }
                alertMessage = error.localizedDescription
            }

            if generation == photoGeneration,
               selectedAsset?.localIdentifier == identifier {
                isLoadingRAW = false
            }
        }
    }
}
