import CoreGraphics
import CoreImage
import Foundation
import UIKit

/// 用图像统计量估算"自动增强"参数，并把结果写入 DemoAdjustmentSettings。
///
/// 说明：苹果"照片"的自动增强由私有管线完成（局部色调映射 + 语义加权），
/// 公开 API 拿不到同等效果。这里的做法是可解释、可回放的统计估算：
/// 曝光 / 对比度 / 高光 / 阴影 / 白平衡 / 自然饱和度 / 清晰度各自独立计算，
/// 结果直接落到滑块上，用户可以继续微调，存档也能完整还原。
enum DemoAutoEnhanceEstimator {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    /// 统计算力上限：只在缩略图上跑，避免每次渲染都分析全分辨率像素。
    private static let analysisDimension: CGFloat = 256

    private struct Statistics {
        var p1: Double
        var p50: Double
        var p99: Double
        var clippedHighRatio: Double
        var clippedLowRatio: Double
        var meanRed: Double
        var meanGreen: Double
        var meanBlue: Double
        var meanSaturation: Double
        var faceLuma: Double?
    }

    static func estimate(from image: CIImage) -> DemoAdjustmentSettings? {
        guard let statistics = statistics(of: image) else { return nil }

        var settings = DemoAdjustmentSettings()

        // 曝光：把中位亮度推向目标值；检测到人脸时以人脸亮度为准，避免背光人像被压暗。
        let targetLuma = statistics.faceLuma == nil ? 0.46 : 0.55
        let referenceLuma = max(statistics.faceLuma ?? statistics.p50, 0.04)
        let exposure = min(max(log2(targetLuma / referenceLuma), -0.8), 0.8)
        settings.exposure = abs(exposure) < 0.08 ? 0 : exposure

        // 对比度：动态范围越平，补得越多；已经很通透就不动。
        let spread = statistics.p99 - statistics.p1
        let contrast = min(max(1 + (0.78 - spread) * 0.45, 1.0), 1.25)
        settings.contrast = contrast - 1 < 0.02 ? 1 : contrast

        // 高光 / 阴影：按溢出比例回压。
        if statistics.clippedHighRatio > 0.015 {
            settings.highlights = min(statistics.clippedHighRatio * 9, 1)
        }
        if statistics.clippedLowRatio > 0.03 {
            settings.shadows = min(statistics.clippedLowRatio * 6, 1)
        }

        // 白平衡：只统计中间调、非过饱和像素，做灰度世界估计。
        let meanRed = max(statistics.meanRed, 0.001)
        let meanBlue = max(statistics.meanBlue, 0.001)
        let warmRatio = meanRed / meanBlue
        let temperature = min(max(6500 * pow(1 / warmRatio, 0.45), 5400), 7600)
        settings.temperature = abs(temperature - 6500) < 60 ? 6500 : temperature

        let meanGreen = max(statistics.meanGreen, 0.001)
        let neutralGreen = (meanRed + meanBlue) / 2
        let tint = min(max((neutralGreen / meanGreen - 1) * 90, -12), 12)
        settings.tint = abs(tint) < 1.5 ? 0 : tint

        // 自然饱和度：饱和度越低补得越多；苹果的自动增强同样不直接动"饱和度"。
        if statistics.meanSaturation > 0.04 {
            settings.vibrance = min(max((0.34 - statistics.meanSaturation) * 0.9, 0.06), 0.32)
        }

        // 清晰度：固定给一点，对应照片里的"定义"。
        settings.sharpness = 0.3

        return settings
    }

    // MARK: - 统计

    private static func statistics(of image: CIImage) -> Statistics? {
        let extent = image.extent
        guard extent.width >= 8, extent.height >= 8 else { return nil }

        let factor = analysisDimension / max(extent.width, extent.height)
        let scaled = image
            .transformed(by: CGAffineTransform(scaleX: factor, y: factor))
            .transformed(by: CGAffineTransform(translationX: -extent.minX * factor,
                                               y: -extent.minY * factor))
        let scaledExtent = scaled.extent.integral
        let width = Int(scaledExtent.width)
        let height = Int(scaledExtent.height)
        guard width > 0, height > 0,
              let cgImage = context.createCGImage(
                scaled,
                from: scaledExtent,
                format: .RGBA8,
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
              ) else { return nil }

        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        let didDraw = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let base = buffer.baseAddress,
                  let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(
                    data: base,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
                  ) else { return false }
            context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard didDraw else { return nil }

        var histogram = [Int](repeating: 0, count: 256)
        var total = 0
        var clippedHigh = 0
        var clippedLow = 0
        var grayRed = 0.0
        var grayGreen = 0.0
        var grayBlue = 0.0
        var grayCount = 0
        var saturationSum = 0.0
        var saturationCount = 0

        for index in stride(from: 0, to: pixels.count, by: 4) {
            let red = Double(pixels[index]) / 255
            let green = Double(pixels[index + 1]) / 255
            let blue = Double(pixels[index + 2]) / 255
            let luma = 0.2126 * red + 0.7152 * green + 0.0722 * blue

            histogram[min(max(Int(luma * 255), 0), 255)] += 1
            total += 1

            if max(red, max(green, blue)) >= 0.985 { clippedHigh += 1 }
            if luma <= 0.02 { clippedLow += 1 }

            let high = max(red, max(green, blue))
            let low = min(red, min(green, blue))
            if high > 0.02 {
                saturationSum += (high - low) / high
                saturationCount += 1
            }

            // 只用中间调、低饱和的像素做白平衡估计，避开霓虹灯与纯色块。
            if luma > 0.08, luma < 0.92, high - low < 0.35 {
                grayRed += red
                grayGreen += green
                grayBlue += blue
                grayCount += 1
            }
        }

        guard total > 0 else { return nil }
        let grayDivisor = max(grayCount, 1)

        return Statistics(
            p1: percentile(histogram, total: total, fraction: 0.01),
            p50: percentile(histogram, total: total, fraction: 0.5),
            p99: percentile(histogram, total: total, fraction: 0.99),
            clippedHighRatio: Double(clippedHigh) / Double(total),
            clippedLowRatio: Double(clippedLow) / Double(total),
            meanRed: grayRed / Double(grayDivisor),
            meanGreen: grayGreen / Double(grayDivisor),
            meanBlue: grayBlue / Double(grayDivisor),
            meanSaturation: saturationCount > 0 ? saturationSum / Double(saturationCount) : 0,
            faceLuma: averageFaceLuma(in: scaled, pixels: pixels, width: width, height: height)
        )
    }

    private static func averageFaceLuma(
        in image: CIImage,
        pixels: [UInt8],
        width: Int,
        height: Int
    ) -> Double? {
        guard let detector = CIDetector(
            ofType: CIDetectorTypeFace,
            context: context,
            options: [CIDetectorAccuracy: CIDetectorAccuracyLow]
        ) else { return nil }

        let features = detector.features(in: image, options: [CIDetectorImageOrientation: 1])
        guard !features.isEmpty else { return nil }

        var lumaSum = 0.0
        var sampleCount = 0

        for feature in features {
            let bounds = feature.bounds
            let startX = max(Int(bounds.minX.rounded(.down)), 0)
            let endX = min(Int(bounds.maxX.rounded(.up)), width - 1)
            let startY = max(Int(bounds.minY.rounded(.down)), 0)
            let endY = min(Int(bounds.maxY.rounded(.up)), height - 1)
            guard endX > startX, endY > startY else { continue }

            var y = startY
            while y <= endY {
                // Core Image 的原点在左下，位图的原点在左上。
                let rowStart = (height - 1 - y) * width
                var x = startX
                while x <= endX {
                    let index = (rowStart + x) * 4
                    let red = Double(pixels[index]) / 255
                    let green = Double(pixels[index + 1]) / 255
                    let blue = Double(pixels[index + 2]) / 255
                    lumaSum += 0.2126 * red + 0.7152 * green + 0.0722 * blue
                    sampleCount += 1
                    x += 2
                }
                y += 2
            }
        }

        guard sampleCount > 0 else { return nil }
        return lumaSum / Double(sampleCount)
    }

    private static func percentile(_ histogram: [Int], total: Int, fraction: Double) -> Double {
        guard total > 0 else { return 0 }
        let target = Int(Double(total) * fraction)
        var cumulative = 0
        for (index, count) in histogram.enumerated() {
            cumulative += count
            if cumulative >= target {
                return Double(index) / 255
            }
        }
        return 1
    }
}
