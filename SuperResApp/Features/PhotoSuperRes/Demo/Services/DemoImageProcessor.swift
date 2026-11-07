import CoreImage
import CoreImage.CIFilterBuiltins
import ImageIO
import PencilKit
import UIKit
import UniformTypeIdentifiers

/// Image rendering backed exclusively by Apple's Core Image built-in filters.
enum DemoImageProcessor {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    /// 预览渲染的最长边上限。预览不需要按原始像素尺寸出图，
    /// 保存时仍走完整的全分辨率管线。
    static let previewMaxDimension: CGFloat = 2048

    /// 解码并归一化输入图像：优先使用内容编辑输入的原片（含 RAW / HDR），
    /// 拿不到时退回 UIImage 的位图并按 EXIF 方向摆正。
    static func sourceCIImage(_ image: UIImage, sourceURL: URL? = nil) -> CIImage? {
        if let sourceURL {
            let sourceType = UTType(filenameExtension: sourceURL.pathExtension)
            if sourceType?.conforms(to: .rawImage) == true {
                if let rawImage = CIRAWFilter(imageURL: sourceURL)?.outputImage {
                    return rawImage
                }
            } else if let decoded = CIImage(
                contentsOf: sourceURL,
                options: [.applyOrientationProperty: true, .expandToHDR: true]
            ) {
                return decoded
            }
        }
        guard let cgImage = image.cgImage else { return nil }
        // Normalize UIImage orientation so that every later stage (analysis,
        // face detection, filters) sees the same upright pixels.
        return CIImage(cgImage: cgImage)
            .oriented(image.imageOrientation.cgImagePropertyOrientation)
    }

    /// Renders with Apple's Core Image filters while retaining the CIImage graph for HDR export.
    static func render(
        _ image: UIImage,
        settings: DemoAdjustmentSettings,
        autoEnhance: Bool = false,
        filterName: String? = nil,
        transform: DemoImageTransform = .identity,
        sourceURL: URL? = nil,
        markupData: Data? = nil
    ) -> UIImage? {
        guard let output = renderCIImage(
            image,
            settings: settings,
            autoEnhance: autoEnhance,
            filterName: filterName,
            transform: transform,
            sourceURL: sourceURL,
            markupData: markupData
        ) else { return nil }
        return makePreviewImage(from: output, scale: image.scale, maxDimension: previewMaxDimension)
    }

    static func renderCIImage(
        _ image: UIImage,
        settings: DemoAdjustmentSettings,
        autoEnhance: Bool = false,
        filterName: String? = nil,
        transform: DemoImageTransform = .identity,
        sourceURL: URL? = nil,
        markupData: Data? = nil
    ) -> CIImage? {
        // `autoEnhance` 仅为兼容既有调用方保留。自动增强已改为参数估算
        // （DemoAutoEnhanceEstimator 把结果写进 settings），不再作为独立渲染阶段，
        // 否则会和用户滑块值重复叠加，且无法回放。
        guard let baseImage = sourceCIImage(image, sourceURL: sourceURL) else { return nil }
        var output = baseImage

        if transform.usesDepthBlur, let sourceURL,
           let depthFilter = context.depthBlurEffectFilter(forImageURL: sourceURL, options: nil),
           let depthImage = depthFilter.outputImage {
            output = depthImage
        }

        // Apply the selected built-in photo-effect preset first, if any.
        if let filterName, let filter = CIFilter(name: filterName) {
            filter.setValue(output, forKey: kCIInputImageKey)
            if let next = filter.outputImage { output = next }
        }

        // 自动增强的参数已经并入 settings，这里统一按滑块值渲染，保证预览与保存一致。
        output = applyAdjustments(settings, to: output)

        if let markupData,
           let drawing = try? PKDrawing(data: markupData) {
            let drawingImage = drawing.image(
                from: CGRect(origin: .zero, size: image.size),
                scale: image.scale
            )
            if let overlay = CIImage(image: drawingImage) {
                let scaleX = output.extent.width / max(overlay.extent.width, 1)
                let scaleY = output.extent.height / max(overlay.extent.height, 1)
                let scaledOverlay = overlay.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))
                let alignedOverlay = scaledOverlay.transformed(by: CGAffineTransform(
                    translationX: output.extent.minX,
                    y: output.extent.minY
                ))
                output = alignedOverlay.composited(over: output)
            }
        }
        output = applyGeometry(transform, to: output)
        return output
    }

    static func makePreviewImage(
        from image: CIImage,
        scale: CGFloat = 1,
        maxDimension: CGFloat? = nil
    ) -> UIImage? {
        var image = image
        if let maxDimension, maxDimension > 0 {
            let sourceExtent = image.extent
            let longestSide = max(sourceExtent.width, sourceExtent.height)
            if longestSide > maxDimension {
                let factor = maxDimension / longestSide
                image = image.transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            }
        }
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

    static func applyGeometry(_ transform: DemoImageTransform, to input: CIImage) -> CIImage {
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

    /// 唯一的参数调整实现。静态图预览、全分辨率导出与 Live Photo 视频帧
    /// 都必须调用这里，避免多份拷贝导致观感不一致。
    static func applyAdjustments(
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
            // The editor's neutral highlight value is 0; Core Image's neutral/default
            // inputHighlightAmount is 1, so invert the normalized slider value.
            filter?.setValue(1 - min(max(settings.highlights, 0), 1), forKey: "inputHighlightAmount")
            filter?.setValue(min(max(settings.shadows, 0), 1), forKey: "inputShadowAmount")
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

// 说明：原先的 AppleAutomaticEnhancement 阶段已移除。
// 它把 CIImage.autoAdjustmentFilters 作为独立管线叠加在用户参数之上，
// 导致滑块显示值与实际画面不符、无法存档回放，并且每次渲染都要重跑人脸检测。
// 现在自动增强改为 DemoAutoEnhanceEstimator 估算参数并直接写入 settings。
