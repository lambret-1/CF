import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

extension DemoPhotoAutoEnhanceView {
func applyAutoEnhance() {
        guard originalImage != nil else { return }
        pushUndo()
        if autoEnhanceEnabled {
            settings = autoEnhanceBaseSettings ?? DemoAdjustmentSettings()
            selectedPreset = autoEnhanceBasePreset ?? .original
            autoEnhanceBaseSettings = nil
            autoEnhanceBasePreset = nil
            autoEnhanceEnabled = false
        } else {
            autoEnhanceBaseSettings = settings
            autoEnhanceBasePreset = selectedPreset
            autoEnhanceEnabled = true
            selectedPreset = .custom
        }
        scheduleRender()
    }

    func applyPreset(_ preset: DemoPhotoPreset) {
        let next = DemoEditorSnapshot(
            settings: preset.settings,
            selectedPreset: preset,
            autoEnhanceEnabled: false,
            autoEnhanceBaseSettings: nil,
            autoEnhanceBasePreset: nil,
            imageTransform: imageTransform,
            markupData: markupData
        )
        guard next != captureSnapshot() else { return }
        pushUndo()
        restoreSnapshot(next)
    }

    func captureSnapshot() -> DemoEditorSnapshot {
        DemoEditorSnapshot(
            settings: settings,
            selectedPreset: selectedPreset,
            autoEnhanceEnabled: autoEnhanceEnabled,
            autoEnhanceBaseSettings: autoEnhanceBaseSettings,
            autoEnhanceBasePreset: autoEnhanceBasePreset,
            imageTransform: imageTransform,
            markupData: markupData
        )
    }

    func restoreSnapshot(_ snapshot: DemoEditorSnapshot) {
        settings = snapshot.settings
        selectedPreset = snapshot.selectedPreset
        autoEnhanceEnabled = snapshot.autoEnhanceEnabled
        autoEnhanceBaseSettings = snapshot.autoEnhanceBaseSettings
        autoEnhanceBasePreset = snapshot.autoEnhanceBasePreset
        imageTransform = snapshot.imageTransform
        markupData = snapshot.markupData
        scheduleRender()
    }

    func pushUndo() {
        let snapshot = captureSnapshot()
        if undoStack.last != snapshot {
            undoStack.append(snapshot)
            if undoStack.count > 40 { undoStack.removeFirst() }
        }
        redoStack.removeAll()
    }

    func undo() {
        guard let previous = undoStack.popLast() else { return }
        redoStack.append(captureSnapshot())
        restoreSnapshot(previous)
    }

    func redo() {
        guard let next = redoStack.popLast() else { return }
        undoStack.append(captureSnapshot())
        restoreSnapshot(next)
    }

    func resetEdits() {
        let next = DemoEditorSnapshot(
            settings: DemoAdjustmentSettings(),
            selectedPreset: .original,
            autoEnhanceEnabled: false,
            autoEnhanceBaseSettings: nil,
            autoEnhanceBasePreset: nil,
            imageTransform: .identity,
            markupData: nil
        )
        guard next != captureSnapshot() else { return }
        pushUndo()
        restoreSnapshot(next)
        compareMode = .result
    }

    func scheduleRender(debounced: Bool = false) {
        guard let originalImage else { return }
        let token = UUID()
        renderToken = token
        isProcessing = true
        let currentSettings = settings
        let useAutoEnhance = autoEnhanceEnabled
        let currentFilterName = selectedPreset.filterName
        let currentTransform = imageTransform
        let currentMarkupData = markupData
        let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL

        renderTask?.cancel()
        renderTask = Task {
            if debounced { try? await Task.sleep(for: .milliseconds(100)) }
            guard !Task.isCancelled, renderToken == token else { return }
            let result = await Task.detached(priority: .userInitiated) {
                DemoImageProcessor.renderCIImage(
                    originalImage,
                    settings: currentSettings,
                    autoEnhance: useAutoEnhance,
                    filterName: currentFilterName,
                    transform: currentTransform,
                    sourceURL: sourceURL,
                    markupData: currentMarkupData
                )
            }.value
            guard !Task.isCancelled, renderToken == token else { return }

            if let result {
                renderedCIImage = result
                let preview = DemoImageProcessor.makePreviewImage(from: result, scale: originalImage.scale) ?? originalImage
                editedImage = preview
            } else {
                renderedCIImage = nil
                editedImage = originalImage
            }
            isProcessing = false
        }
    }
}
