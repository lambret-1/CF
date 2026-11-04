import Foundation
import Photos
import ImageIO
import UniformTypeIdentifiers
import UIKit

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
        guard let url = input.fullSizeImageURL,
              let image = UIImage(contentsOfFile: url.path) else {
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
               type.conforms(to: .image) {
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
        }
    }
}
