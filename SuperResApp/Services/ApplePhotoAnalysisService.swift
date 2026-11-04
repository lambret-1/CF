import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import Vision

struct ApplePhotoAnalysisResult {
    let faceCount: Int
    let horizonAngle: CGFloat?
    let foregroundInstanceCount: Int
    let foregroundMask: CVPixelBuffer?
    let depthData: AVDepthData?
}

/// Uses Apple's Vision, AVFoundation, ImageIO, and Core Image APIs only.
enum ApplePhotoAnalysisService {
    static func analyze(_ image: UIImage) throws -> ApplePhotoAnalysisResult {
        guard let cgImage = image.cgImage else {
            throw ApplePhotoAnalysisError.imageUnavailable
        }
        let orientation = image.imageOrientation.cgImagePropertyOrientation
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let faces = VNDetectFaceRectanglesRequest()
        let horizon = VNDetectHorizonRequest()
        let foreground = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([faces, horizon, foreground])

        let foregroundObservation = foreground.results?.first
        let mask: CVPixelBuffer?
        if let observation = foregroundObservation {
            mask = try observation.generateScaledMaskForImage(
                forInstances: observation.allInstances,
                from: handler
            )
        } else {
            mask = nil
        }

        return ApplePhotoAnalysisResult(
            faceCount: faces.results?.count ?? 0,
            horizonAngle: horizon.results?.first?.angle,
            foregroundInstanceCount: foregroundObservation?.allInstances.count ?? 0,
            foregroundMask: mask,
            depthData: depthData(from: image)
        )
    }

    static func depthData(from image: UIImage) -> AVDepthData? {
        guard let cgImage = image.cgImage,
              let data = image.jpegData(compressionQuality: 1),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
                source,
                0,
                kCGImageAuxiliaryDataTypeDisparity
              ) as? [AnyHashable: Any] else {
            return nil
        }
        return try? AVDepthData(fromDictionaryRepresentation: auxiliary)
            .converting(toDepthDataType: kCVPixelFormatType_DepthFloat32)
    }

    static func renderRawImage(at url: URL) throws -> UIImage {
        guard let rawFilter = CIRAWFilter(imageURL: url),
              let output = rawFilter.outputImage else {
            throw ApplePhotoAnalysisError.rawDecodeFailed
        }
        let context = CIContext()
        let extent = output.extent.integral
        guard let cgImage = context.createCGImage(output, from: extent) else {
            throw ApplePhotoAnalysisError.rawDecodeFailed
        }
        return UIImage(cgImage: cgImage)
    }

    static func isRawResource(_ resource: PHAssetResource) -> Bool {
        guard let type = UTType(resource.uniformTypeIdentifier) else { return false }
        return type.conforms(to: .rawImage)
    }
}

enum ApplePhotoAnalysisError: LocalizedError {
    case imageUnavailable
    case rawDecodeFailed

    var errorDescription: String? {
        switch self {
        case .imageUnavailable: return "无法读取用于 Vision 分析的图像。"
        case .rawDecodeFailed: return "Apple Core Image RAW 解码失败。"
        }
    }
}

private extension UIImage.Orientation {
    var cgImagePropertyOrientation: CGImagePropertyOrientation {
        switch self {
        case .up: .up
        case .down: .down
        case .left: .left
        case .right: .right
        case .upMirrored: .upMirrored
        case .downMirrored: .downMirrored
        case .leftMirrored: .leftMirrored
        case .rightMirrored: .rightMirrored
        @unknown default: .up
        }
    }
}
