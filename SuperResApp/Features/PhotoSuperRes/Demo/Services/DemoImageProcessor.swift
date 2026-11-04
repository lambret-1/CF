import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import UIKit

enum DemoImageProcessor {
    static func render(_ image: UIImage, settings: DemoAdjustmentSettings, autoEnhance: Bool = false) -> UIImage? {
        guard let input = orientedCIImage(from: image) else { return nil }
        var output = input

        if autoEnhance {
            let options: [CIImageAutoAdjustmentOption: Any] = [
                .crop: false,
                .imageOrientation: NSNumber(value: CGImagePropertyOrientation.up.rawValue)
            ]
            for filter in input.autoAdjustmentFilters(options: options) {
                filter.setValue(output, forKey: kCIInputImageKey)
                if let next = filter.outputImage { output = next }
            }
        }

        let exposure = CIFilter.exposureAdjust()
        exposure.inputImage = output
        exposure.ev = Float(settings.exposure)
        if let next = exposure.outputImage { output = next }

        let controls = CIFilter.colorControls()
        controls.inputImage = output
        controls.brightness = Float(settings.brightness)
        controls.contrast = Float(settings.contrast)
        controls.saturation = Float(settings.saturation)
        if let next = controls.outputImage { output = next }

        if abs(settings.temperature) > 0.01 {
            let temperature = CIFilter.temperatureAndTint()
            temperature.inputImage = output
            temperature.neutral = CIVector(x: 6500, y: 0)
            temperature.targetNeutral = CIVector(x: CGFloat(6500 + settings.temperature * 22), y: 0)
            if let next = temperature.outputImage { output = next }
        }

        let highlightShadow = CIFilter.highlightShadowAdjust()
        highlightShadow.inputImage = output
        highlightShadow.highlightAmount = Float(1 - settings.highlights * 0.45)
        highlightShadow.shadowAmount = Float(1 + settings.shadows * 0.85)
        if let next = highlightShadow.outputImage { output = next }

        if settings.sharpness > 0.001 {
            let sharpen = CIFilter.sharpenLuminance()
            sharpen.inputImage = output
            sharpen.sharpness = Float(settings.sharpness)
            if let next = sharpen.outputImage { output = next }
        }

        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: .up)
    }

    private static func orientedCIImage(from image: UIImage) -> CIImage? {
        guard let cgImage = image.cgImage else { return nil }
        return CIImage(cgImage: cgImage).oriented(image.imageOrientation.cgImagePropertyOrientation)
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
