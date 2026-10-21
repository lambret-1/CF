// SuperResApp/Services/PhotoLibraryService.swift
// 相册服务：保存图片到相册、权限管理

import Foundation
import Photos
import UIKit

/// 相册服务，负责图片保存和权限管理
actor PhotoLibraryService {
    /// 单例
    static let shared = PhotoLibraryService()

    private init() {}

    // MARK: - 权限

    /// 当前相册写入权限状态
    var authorizationStatus: PHAuthorizationStatus {
        PHPhotoLibrary.authorizationStatus(for: .addOnly)
    }

    /// 请求相册写入权限
    func requestAuthorization() async -> PHAuthorizationStatus {
        await withCheckedContinuation { continuation in
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                continuation.resume(returning: status)
            }
        }
    }

    /// 检查是否有权限，没有则请求
    func ensureAuthorization() async -> Bool {
        let status = authorizationStatus
        switch status {
        case .authorized, .limited:
            return true
        case .notDetermined:
            let newStatus = await requestAuthorization()
            return newStatus == .authorized || newStatus == .limited
        case .denied, .restricted:
            return false
        @unknown default:
            return false
        }
    }

    // MARK: - 保存图片

    /// 保存 CGImage 到相册
    /// - Parameter image: 图片
    /// - Returns: 是否成功
    func save(_ image: CGImage) async throws {
        let hasPermission = await ensureAuthorization()
        guard hasPermission else {
            throw PhotoLibraryError.permissionDenied
        }

        let uiImage = UIImage(cgImage: image)

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                PHAssetChangeRequest.creationRequestForAsset(from: uiImage)
            }) { success, error in
                if success {
                    continuation.resume()
                } else if let error = error {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed("未知错误"))
                }
            }
        }
    }

    /// 保存图片数据到相册（HEIF/PNG）
    /// - Parameters:
    ///   - data: 图片数据
    ///   - type: 图片类型
    func save(data: Data, type: PhotoImageType) async throws {
        let hasPermission = await ensureAuthorization()
        guard hasPermission else {
            throw PhotoLibraryError.permissionDenied
        }

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges({
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: type == .heif ? .photo : .photo, data: data, options: nil)
            }) { success, error in
                if success {
                    continuation.resume()
                } else if let error = error {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed(error.localizedDescription))
                } else {
                    continuation.resume(throwing: PhotoLibraryError.saveFailed("未知错误"))
                }
            }
        }
    }

    /// 将 CGImage 转为 HEIF 数据
    func heifData(from image: CGImage, quality: CGFloat = 0.9) -> Data? {
        let uiImage = UIImage(cgImage: image)
        guard let cgImage = uiImage.cgImage else { return nil }
        let mutableData = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            mutableData,
            "public.heif" as CFString,
            1,
            nil
        ) else { return nil }
        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return mutableData as Data
    }

    /// 将 CGImage 转为 PNG 数据
    func pngData(from image: CGImage) -> Data? {
        let uiImage = UIImage(cgImage: image)
        return uiImage.pngData()
    }
}

// MARK: - 图片类型

enum PhotoImageType {
    case heif
    case png
}

// MARK: - 错误

enum PhotoLibraryError: LocalizedError {
    case permissionDenied
    case saveFailed(String)

    var errorDescription: String? {
        switch self {
        case .permissionDenied:
            return "没有相册权限，请在设置中允许访问相册"
        case .saveFailed(let detail):
            return "保存失败：\(detail)"
        }
    }
}
