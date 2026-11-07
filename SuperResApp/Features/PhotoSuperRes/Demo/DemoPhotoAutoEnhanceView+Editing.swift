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
        guard let image = originalImage else { return }
        let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL

        // 已在自动增强状态：再次点击恢复到应用前的基线。
        if autoEnhanceEnabled, let base = autoEnhanceBaseSettings {
            pushUndo()
            settings = base
            if let basePreset = autoEnhanceBasePreset {
                selectedPreset = basePreset
            }
            autoEnhanceEnabled = false
            autoEnhanceBaseSettings = nil
            autoEnhanceBasePreset = nil
            scheduleRender()
            return
        }

        guard let source = DemoImageProcessor.sourceCIImage(image, sourceURL: sourceURL) else {
            alertMessage = "无法读取这张照片的像素数据，自动增强未应用。"
            return
        }
        guard let estimate = DemoAutoEnhanceEstimator.estimate(from: source) else {
            alertMessage = "无法分析这张照片，自动增强未应用。"
            return
        }

        pushUndo()
        // 估算结果直接落到滑块上：用户可以继续微调，存档也能完整还原。
        autoEnhanceBaseSettings = settings
        autoEnhanceBasePreset = selectedPreset
        settings = estimate
        autoEnhanceEnabled = true
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
                    filterName: currentFilterName,
                    transform: currentTransform,
                    sourceURL: sourceURL,
                    markupData: currentMarkupData
                )
            }.value
            guard !Task.isCancelled, renderToken == token else { return }

            if let result {
                renderedCIImage = result
                // 预览只出 2048px 以内的位图；全分辨率像素只在保存时算一次。
                let preview = DemoImageProcessor.makePreviewImage(
                    from: result,
                    scale: originalImage.scale,
                    maxDimension: DemoImageProcessor.previewMaxDimension
                ) ?? originalImage
                editedImage = preview
            } else {
                renderedCIImage = nil
                editedImage = originalImage
            }
            isProcessing = false
        }
    }
}
