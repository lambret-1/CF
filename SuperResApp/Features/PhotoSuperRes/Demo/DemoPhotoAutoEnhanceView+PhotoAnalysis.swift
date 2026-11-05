import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

extension DemoPhotoAutoEnhanceView {
    func extractForegroundSubject() {
        guard let image = originalImage else { return }
        let generation = photoGeneration
        let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL
        isExtractingSubject = true

        Task {
            do {
                let cutout = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.foregroundCutout(from: image, sourceURL: sourceURL)
                }.value

                guard generation == photoGeneration else { return }
                foregroundCutout = cutout
                if cutout == nil {
                    alertMessage = "Vision 未检测到可分离的前景主体。"
                }
            } catch {
                guard generation == photoGeneration else { return }
                alertMessage = error.localizedDescription
            }

            if generation == photoGeneration {
                isExtractingSubject = false
            }
        }
    }

    func analyzeCurrentPhoto() {
        guard let image = originalImage else { return }
        let generation = photoGeneration
        let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL
        isAnalyzing = true

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.analyze(image, sourceURL: sourceURL)
                }.value

                guard generation == photoGeneration else { return }
                analysisResult = result
            } catch {
                guard generation == photoGeneration else { return }
                alertMessage = error.localizedDescription
            }

            if generation == photoGeneration {
                isAnalyzing = false
            }
        }
    }

    func analysisMetric(_ title: String, value: String) -> some View {
        VStack(spacing: 3) {
            Text(value).font(.system(size: 12, weight: .semibold, design: .rounded))
            Text(title).font(.system(size: 9)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }
}
