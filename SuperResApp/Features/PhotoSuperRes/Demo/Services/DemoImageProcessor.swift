import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit
import UniformTypeIdentifiers

/// Image rendering backed exclusively by Apple's Core Image built-in filters.
enum DemoImageProcessor {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Renders with Apple's Core Image filters while retaining the CIImage graph for HDR export.
    static func render(
        _ image: UIImage,
        settings: DemoAdjustmentSettings,
        autoEnhance: Bool = false,
        filterName: String? = nil,
        transform: DemoImageTransform = .identity,
        sourceURL: URL? = nil
    ) -> UIImage? {
        guard let output = renderCIImage(
            image,
            settings: settings,
            autoEnhance: autoEnhance,
            filterName: filterName,
            transform: transform,
            sourceURL: sourceURL
        ) else { return nil }
        return makePreviewImage(from: output, scale: image.scale)
    }

    static func renderCIImage(
        _ image: UIImage,
        settings: DemoAdjustmentSettings,
        autoEnhance: Bool = false,
        filterName: String? = nil,
        transform: DemoImageTransform = .identity,
        sourceURL: URL? = nil
    ) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let sourceType = sourceURL.flatMap { UTType(filenameExtension: $0.pathExtension) }
        let isRaw = sourceType?.conforms(to: .rawImage) == true
        let sourceImage: CIImage?
        if let sourceURL, isRaw {
            sourceImage = CIRAWFilter(imageURL: sourceURL)?.outputImage
        } else if let sourceURL {
            sourceImage = CIImage(
                contentsOf: sourceURL,
                options: [.applyOrientationProperty: true, .expandToHDR: true]
            )
        } else {
            sourceImage = nil
        }

        let hasDecodedSourceURL = sourceImage != nil
        let orientation = hasDecodedSourceURL ? CGImagePropertyOrientation.up : image.imageOrientation.cgImagePropertyOrientation
        let input = sourceImage ?? CIImage(cgImage: cgImage)
        var output = input

        if transform.usesDepthBlur, let sourceURL,
           let depthFilter = context.depthBlurEffectFilter(forImageURL: sourceURL, options: nil),
           let depthImage = depthFilter.outputImage {
            output = depthImage
        }

        if autoEnhance {
            let options: [CIImageAutoAdjustmentOption: Any] = [
                .crop: false,
                CIImageAutoAdjustmentOption(rawValue: "CIDetectorImageOrientation"): NSNumber(value: orientation.rawValue)
            ]

            for filter in input.autoAdjustmentFilters(options: options) {
                filter.setValue(output, forKey: kCIInputImageKey)
                guard let next = filter.outputImage else { continue }
                output = next
            }
        } else {
            if let filterName, let filter = CIFilter(name: filterName) {
                filter.setValue(output, forKey: kCIInputImageKey)
                if let next = filter.outputImage { output = next }
            }
            output = applyManualAdjustments(settings, to: output)
        }

        if !hasDecodedSourceURL {
            output = output.oriented(orientation)
        }
        output = applyGeometry(transform, to: output)
        return output
    }

    static func makePreviewImage(from image: CIImage, scale: CGFloat = 1) -> UIImage? {
        let extent = image.extent.integral
        guard !extent.isEmpty,
              let rendered = context.createCGImage(
                image,
                from: extent,
                format: .RGBAh,
                colorSpace: image.colorSpace
              ) else {
            return nil
        }
        return UIImage(cgImage: rendered, scale: scale, orientation: .up)
    }

    private static func applyGeometry(_ transform: DemoImageTransform, to input: CIImage) -> CIImage {
        var output = input
        if transform.usesPerspectiveCorrection,
           let corrected = try? ApplePhotoAnalysisService.perspectiveCorrect(output) {
            output = corrected
        }

        if abs(transform.straightenAngle) > 0.0001,
           let filter = CIFilter(name: "CIStraightenFilter") {
            filter.setValue(output, forKey: kCIInputImageKey)
            filter.setValue(transform.straightenAngle, forKey: "inputAngle")
            if let next = filter.outputImage { output = next }
        }

        let turns = ((transform.quarterTurnsClockwise % 4) + 4) % 4

        switch turns {
        case 1: output = output.oriented(.right)
        case 2: output = output.oriented(.down)
        case 3: output = output.oriented(.left)
        default: break
        }

        if transform.isHorizontallyFlipped {
            output = output.oriented(.upMirrored)
        }

        let bounds = output.extent.integral
        if let cropRect = transform.cropRect {
            output = output.cropped(to: CGRect(
                x: bounds.minX + cropRect.minX * bounds.width,
                y: bounds.minY + (1 - cropRect.maxY) * bounds.height,
                width: cropRect.width * bounds.width,
                height: cropRect.height * bounds.height
            ))
        } else if let aspectRatio = transform.cropAspectRatio, aspectRatio > 0 {
            let width = min(bounds.width, bounds.height * aspectRatio)
            let height = min(bounds.height, bounds.width / aspectRatio)
            output = output.cropped(to: CGRect(
                x: bounds.midX - width / 2,
                y: bounds.midY - height / 2,
                width: width,
                height: height
            ))
        } else if transform.usesSquareCrop {
            let side = min(bounds.width, bounds.height)
            output = output.cropped(to: CGRect(
                x: bounds.midX - side / 2,
                y: bounds.midY - side / 2,
                width: side,
                height: side
            ))
        }

        return output
    }

    private static func applyManualAdjustments(
        _ settings: DemoAdjustmentSettings,
        to input: CIImage
    ) -> CIImage {
        var output = input

        if abs(settings.exposure) > 0.0001 {
            let filter = CIFilter.exposureAdjust()
            filter.inputImage = output
            filter.ev = Float(settings.exposure)
            if let next = filter.outputImage { output = next }
        }

        if abs(settings.brightness) > 0.0001 ||
            abs(settings.contrast - 1) > 0.0001 ||
            abs(settings.saturation - 1) > 0.0001 {
            let filter = CIFilter.colorControls()
            filter.inputImage = output
            filter.brightness = Float(settings.brightness)
            filter.contrast = Float(settings.contrast)
            filter.saturation = Float(settings.saturation)
            if let next = filter.outputImage { output = next }
        }

        if abs(settings.vibrance) > 0.0001 {
            let filter = CIFilter(name: "CIVibrance")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(settings.vibrance, forKey: "inputAmount")
            if let next = filter?.outputImage { output = next }
        }

        if abs(settings.highlights) > 0.0001 || abs(settings.shadows) > 0.0001 {
            let filter = CIFilter(name: "CIHighlightShadowAdjust")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(settings.highlights, forKey: "inputHighlightAmount")
            filter?.setValue(settings.shadows, forKey: "inputShadowAmount")
            if let next = filter?.outputImage { output = next }
        }

        if abs(settings.temperature - 6500) > 0.5 || abs(settings.tint) > 0.0001 {
            let filter = CIFilter(name: "CITemperatureAndTint")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(CIVector(x: 6500, y: 0), forKey: "inputNeutral")
            filter?.setValue(CIVector(x: settings.temperature, y: settings.tint), forKey: "inputTargetNeutral")
            if let next = filter?.outputImage { output = next }
        }

        if abs(settings.sharpness) > 0.0001 {
            let filter = CIFilter(name: "CISharpenLuminance")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(settings.sharpness, forKey: "inputSharpness")
            if let next = filter?.outputImage { output = next }
        }

        if abs(settings.noiseReduction) > 0.0001 {
            let filter = CIFilter(name: "CINoiseReduction")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(settings.noiseReduction, forKey: "inputNoiseLevel")
            filter?.setValue(0.4, forKey: "inputSharpness")
            if let next = filter?.outputImage { output = next }
        }

        if abs(settings.vignette) > 0.0001 {
            let filter = CIFilter(name: "CIVignette")
            filter?.setValue(output, forKey: kCIInputImageKey)
            filter?.setValue(settings.vignette, forKey: "inputIntensity")
            filter?.setValue(max(output.extent.width, output.extent.height) * 0.75, forKey: "inputRadius")
            if let next = filter?.outputImage { output = next }
        }

        return output
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
