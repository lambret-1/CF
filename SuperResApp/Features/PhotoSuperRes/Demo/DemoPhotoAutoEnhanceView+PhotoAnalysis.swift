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
        isExtractingSubject = true
        Task {
            do {
                let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL
                foregroundCutout = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.foregroundCutout(from: image, sourceURL: sourceURL)
                }.value
                if foregroundCutout == nil {
                    alertMessage = "Vision 未检测到可分离的前景主体。"
                }
            } catch {
                alertMessage = error.localizedDescription
            }
            isExtractingSubject = false
        }
    }

    func analyzeCurrentPhoto() {
        guard let image = originalImage else { return }
        isAnalyzing = true
        Task {
            do {
                let sourceURL = renderSourceURL ?? editingInput?.fullSizeImageURL
                let result = try await Task.detached(priority: .userInitiated) {
                    try ApplePhotoAnalysisService.analyze(image, sourceURL: sourceURL)
                }.value
                analysisResult = result
            } catch {
                alertMessage = error.localizedDescription
            }
            isAnalyzing = false
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
