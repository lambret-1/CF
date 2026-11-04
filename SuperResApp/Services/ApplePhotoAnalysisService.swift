import AVFoundation
import CoreImage
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
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
    static func analyze(_ image: UIImage, sourceURL: URL? = nil) throws -> ApplePhotoAnalysisResult {
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
            depthData: sourceURL.flatMap { depthData(from: $0) } ?? depthData(from: image)
        )
    }

    static func perspectiveCorrect(_ image: CIImage) throws -> CIImage? {
        let request = VNDetectRectanglesRequest()
        request.maximumObservations = 1
        request.minimumConfidence = 0.55
        request.minimumAspectRatio = 0.25
        request.quadratureTolerance = 25
        let handler = VNImageRequestHandler(ciImage: image, options: [:])
        try handler.perform([request])
        guard let rectangle = request.results?.first else { return nil }

        let bounds = image.extent
        func point(_ normalized: CGPoint) -> CIVector {
            CIVector(cgPoint: CGPoint(
                x: bounds.minX + normalized.x * bounds.width,
                y: bounds.minY + normalized.y * bounds.height
            ))
        }

        let filter = CIFilter(name: "CIPerspectiveCorrection")
        filter?.setValue(image, forKey: kCIInputImageKey)
        filter?.setValue(point(rectangle.topLeft), forKey: "inputTopLeft")
        filter?.setValue(point(rectangle.topRight), forKey: "inputTopRight")
        filter?.setValue(point(rectangle.bottomLeft), forKey: "inputBottomLeft")
        filter?.setValue(point(rectangle.bottomRight), forKey: "inputBottomRight")
        return filter?.outputImage
    }

    static func horizonAngle(for image: UIImage) throws -> CGFloat? {
        guard let cgImage = image.cgImage else {
            throw ApplePhotoAnalysisError.imageUnavailable
        }
        let request = VNDetectHorizonRequest()
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: image.imageOrientation.cgImagePropertyOrientation,
            options: [:]
        )
        try handler.perform([request])
        return request.results?.first?.angle
    }

    static func foregroundCutout(from image: UIImage) throws -> UIImage? {
        guard let cgImage = image.cgImage else {
            throw ApplePhotoAnalysisError.imageUnavailable
        }
        let handler = VNImageRequestHandler(
            cgImage: cgImage,
            orientation: image.imageOrientation.cgImagePropertyOrientation,
            options: [:]
        )
        let request = VNGenerateForegroundInstanceMaskRequest()
        try handler.perform([request])
        guard let observation = request.results?.first else { return nil }
        let maskBuffer = try observation.generateScaledMaskForImage(
            forInstances: observation.allInstances,
            from: handler
        )

        let foreground = CIImage(cgImage: cgImage)
        let mask = CIImage(cvPixelBuffer: maskBuffer)
        let transparentBackground = CIImage(color: .clear).cropped(to: foreground.extent)
        let blend = CIFilter(name: "CIBlendWithMask")
        blend?.setValue(foreground, forKey: kCIInputImageKey)
        blend?.setValue(transparentBackground, forKey: kCIInputBackgroundImageKey)
        blend?.setValue(mask, forKey: "inputMaskImage")
        guard let output = blend?.outputImage,
              let rendered = CIContext().createCGImage(output, from: foreground.extent) else {
            return nil
        }
        return UIImage(cgImage: rendered, scale: image.scale, orientation: .up)
    }

    static func depthData(from image: UIImage) -> AVDepthData? {
        guard let data = image.jpegData(compressionQuality: 1),
              let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            return nil
        }
        return depthData(from: source)
    }

    static func depthData(from sourceURL: URL) -> AVDepthData? {
        guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil) else {
            return nil
        }
        return depthData(from: source)
    }

    private static func depthData(from source: CGImageSource) -> AVDepthData? {
        guard let auxiliary = CGImageSourceCopyAuxiliaryDataInfoAtIndex(
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
