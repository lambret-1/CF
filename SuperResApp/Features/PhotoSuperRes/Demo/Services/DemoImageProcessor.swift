import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

/// Image rendering backed exclusively by Apple's Core Image built-in filters.
enum DemoImageProcessor {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Auto enhancement uses only the adjustment filters returned by Core Image.
    /// Manual controls are applied only in manual mode and map to built-in CIFilters.
    static func render(
        _ image: UIImage,
        settings: DemoAdjustmentSettings,
        autoEnhance: Bool = false,
        filterName: String? = nil,
        transform: DemoImageTransform = .identity
    ) -> UIImage? {
        guard let cgImage = image.cgImage else { return nil }

        let orientation = image.imageOrientation.cgImagePropertyOrientation
        let input = CIImage(cgImage: cgImage)
        var output = input

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

        // UIImage(cgImage:) does not retain UIImage's original orientation metadata.
        // Normalize the rendered pixels exactly once before returning an upright image.
        output = output.oriented(orientation)
        output = applyGeometry(transform, to: output)
        let extent = output.extent.integral
        guard !extent.isEmpty,
              let renderedImage = context.createCGImage(output, from: extent) else {
            return nil
        }

        return UIImage(cgImage: renderedImage, scale: image.scale, orientation: .up)
    }

    private static func applyGeometry(_ transform: DemoImageTransform, to input: CIImage) -> CIImage {
        var output = input
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

        if transform.usesSquareCrop {
            let bounds = output.extent.integral
            let side = min(bounds.width, bounds.height)
            let cropRect = CGRect(
                x: bounds.midX - side / 2,
                y: bounds.midY - side / 2,
                width: side,
                height: side
            )
            output = output.cropped(to: cropRect)
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
