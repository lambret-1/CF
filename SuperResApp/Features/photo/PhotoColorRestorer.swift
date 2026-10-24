import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

final class PhotoColorRestorer {
    private let ciContext: CIContext
    private let linearSRGB: CGColorSpace
    private let sRGB: CGColorSpace

    init() {
        // 优化 1：移除 NSNull()，显式指定扩展线性 sRGB 作为工作色彩空间
        // Core Image 会自动把输入 CIImage（如 sRGB、P3）匹配到该工作空间
        // 并在输出时按请求的目标色彩空间转换回去
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            fatalError("无法创建标准色彩空间")
        }
        self.linearSRGB = linear
        self.sRGB = srgb
        self.ciContext = CIContext(options: [
            .cacheIntermediates: false,
            .workingColorSpace: linear
        ])
    }

    /// 业界标准：直方图修剪 + 中性像素筛选 + 强度加权 + Bradford 色适应变换
    func autoRestoreColor(image: UIImage) -> UIImage? {
        logInfo("==== 开始真实色彩还原 ====")
        logInfo("原图尺寸: \(Int(image.size.width))x\(Int(image.size.height))")

        guard let ciImage = CIImage(image: image) else {
            logError("CIImage 转换失败")
            return image
        }

        // 1. 缩小分析样本
        // 优化 1 续：移除手动 CISRGBToneCurveToLinear
        // 输入 CIImage 会被自动转换到线性工作空间；手动再调用会双重线性化
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(0.05, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)

        guard let smallImage = scaleFilter.outputImage else {
            logError("图像缩放失败")
            return image
        }

        let extent = smallImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else {
            logError("分析图像尺寸无效")
            return image
        }

        logInfo("分析采样尺寸: \(width)x\(height) (线性空间)")

        var bitmap = [Float](repeating: 0, count: width * height * 4)
        // colorSpace: nil → 直接返回工作空间（线性 sRGB）中的值
        ciContext.render(smallImage,
                         toBitmap: &bitmap,
                         rowBytes: width * 4 * MemoryLayout<Float>.size,
                         bounds: extent,
                         format: .RGBAf,
                         colorSpace: nil)

        struct Pixel {
            let r: Float
            let g: Float
            let b: Float
            let luma: Float
        }

        var pixels: [Pixel] = []
        pixels.reserveCapacity(width * height)

        for i in 0..<(width * height) {
            let offset = i * 4
            let r = bitmap[offset]
            let g = bitmap[offset + 1]
            let b = bitmap[offset + 2]
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            pixels.append(Pixel(r: r, g: g, b: b, luma: luma))
        }

        // 2. 直方图修剪：剔除最暗 / 最亮 2%
        pixels.sort { $0.luma < $1.luma }
        let trimCount = Int(Float(pixels.count) * 0.02)
        guard pixels.count > trimCount * 2 + 100 else {
            logError("有效像素过少，放弃计算")
            return image
        }
        let validPixels = pixels[trimCount..<(pixels.count - trimCount)]
        logInfo("直方图修剪完成: 剔除 \(trimCount * 2) 个极值像素，保留 \(validPixels.count) 个")

        // 3. 三重加权：亮度权重 × 中性度权重 × 高光抑制
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var totalWeight: Float = 0

        // 兜底统计：不做中性筛选（用于大面积单色场景）
        var fallbackSumR: Float = 0
        var fallbackSumG: Float = 0
        var fallbackSumB: Float = 0
        var fallbackWeight: Float = 0

        // 优化 2 参数：饱和度越高，中性度权重越低（高斯衰减）
        // sigma = 0.25 → 饱和度 0.25 权重 ≈ 0.61，饱和度 0.5 权重 ≈ 0.135
        let neutralSigma: Float = 0.25
        let neutralSigma2 = 2 * neutralSigma * neutralSigma

        // 优化 3 参数：线性域 luma > 0.85 开始衰减，≥ 1.0 完全剔除
        // 目的：抑制直射光源/过曝区域主导白点估计
        let highlightStart: Float = 0.85
        let highlightEnd: Float = 1.0

        for p in validPixels {
            // 基础亮度权重（抵抗暗部噪声）
            let lumaWeight = max(p.luma, 0.01)

            // 中性度权重：接近中性的像素更可能是"灰体反射面"
            let maxC = max(p.r, max(p.g, p.b))
            let minC = min(p.r, min(p.g, p.b))
            let denom = max(maxC, 1e-6)
            let saturation = (maxC - minC) / denom
            let neutralWeight = exp(-(saturation * saturation) / neutralSigma2)

            // 高光抑制
            let highlightWeight: Float
            if p.luma >= highlightEnd {
                highlightWeight = 0
            } else if p.luma > highlightStart {
                let t = (p.luma - highlightStart) / (highlightEnd - highlightStart)
                highlightWeight = 1 - t * t
            } else {
                highlightWeight = 1
            }

            let weight = lumaWeight * neutralWeight * highlightWeight
            sumR += p.r * weight
            sumG += p.g * weight
            sumB += p.b * weight
            totalWeight += weight

            let fbWeight = lumaWeight * highlightWeight
            fallbackSumR += p.r * fbWeight
            fallbackSumG += p.g * fbWeight
            fallbackSumB += p.b * fbWeight
            fallbackWeight += fbWeight
        }

        // 若中性筛选后权重不足（场景几乎无中性物体），退化为灰度世界
        let minAcceptableWeight = Float(validPixels.count) * 0.02
        let useNeutralFilter = totalWeight > 0 && totalWeight >= minAcceptableWeight

        let srcR: Double
        let srcG: Double
        let srcB: Double

        if useNeutralFilter {
            srcR = Double(sumR / totalWeight)
            srcG = Double(sumG / totalWeight)
            srcB = Double(sumB / totalWeight)
            logInfo("采用【中性像素筛选】估计光源")
        } else if fallbackWeight > 0 {
            srcR = Double(fallbackSumR / fallbackWeight)
            srcG = Double(fallbackSumG / fallbackWeight)
            srcB = Double(fallbackSumB / fallbackWeight)
            logInfo("中性像素不足，退化为【灰度世界 + 高光抑制】估计")
        } else {
            logError("总权重为 0，计算异常")
            return image
        }

        logInfo(String(format: "估计光源 (线性 RGB): R=%.4f, G=%.4f, B=%.4f", srcR, srcG, srcB))

        // 4. Bradford CAT
        let M_sRGB2XYZ: [[Double]] = [
            [0.4124564, 0.3575761, 0.1804375],
            [0.2126729, 0.7151522, 0.0721750],
            [0.0193339, 0.1191920, 0.9503041]
        ]
        let M_Bradford: [[Double]] = [
            [ 0.8951,  0.2664, -0.1614],
            [-0.7502,  1.7135,  0.0367],
            [ 0.0389, -0.0685,  1.0296]
        ]
        let M_BradfordInv: [[Double]] = [
            [ 0.9869929, -0.1470543,  0.1599627],
            [ 0.4323053,  0.5183603,  0.0492912],
            [-0.0085287,  0.0400428,  0.9684867]
        ]
        let M_XYZ2sRGB: [[Double]] = [
            [ 3.2404542, -1.5371385, -0.4985314],
            [-0.9692660,  1.8760108,  0.0415560],
            [ 0.0556434, -0.2040259,  1.0572252]
        ]

        let srcXYZ = multiplyMatrixVector(matrix: M_sRGB2XYZ, vector: [srcR, srcG, srcB])
        let srcLMS = multiplyMatrixVector(matrix: M_Bradford, vector: srcXYZ)

        // D65 参考白
        let dstLMS: [Double] = [0.95047, 1.0, 1.08883]
        let dstLMS_Bradford = multiplyMatrixVector(matrix: M_Bradford, vector: dstLMS)

        let gainL = dstLMS_Bradford[0] / max(srcLMS[0], 0.001)
        let gainM = dstLMS_Bradford[1] / max(srcLMS[1], 0.001)
        let gainS = dstLMS_Bradford[2] / max(srcLMS[2], 0.001)
        logInfo(String(format: "LMS 锥体细胞增益: L=%.4f, M=%.4f, S=%.4f", gainL, gainM, gainS))

        let M_gain: [[Double]] = [
            [gainL, 0, 0],
            [0, gainM, 0],
            [0, 0, gainS]
        ]

        let step1 = multiplyMatrices(M_Bradford, M_sRGB2XYZ)
        let step2 = multiplyMatrices(M_gain, step1)
        let step3 = multiplyMatrices(M_BradfordInv, step2)
        let M_final = multiplyMatrices(M_XYZ2sRGB, step3)
        logInfo("Bradford 色适应 3×3 矩阵计算完成")

        // 5. 应用矩阵（在线性工作空间运算，无需手动线性化）
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = ciImage
        colorMatrix.rVector = CIVector(x: M_final[0][0], y: M_final[0][1], z: M_final[0][2], w: 0)
        colorMatrix.gVector = CIVector(x: M_final[1][0], y: M_final[1][1], z: M_final[1][2], w: 0)
        colorMatrix.bVector = CIVector(x: M_final[2][0], y: M_final[2][1], z: M_final[2][2], w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)

        guard let matrixOutput = colorMatrix.outputImage else {
            logError("色彩矩阵应用失败")
            return image
        }

        // 优化 4：在转回 sRGB 前显式钳制到 [0, 1]
        // Bradford LMS 增益在极端色偏下可能产生负值或超 1 的线性值
        let clampFilter = CIFilter.colorClamp()
        clampFilter.inputImage = matrixOutput
        clampFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        guard let clampedImage = clampFilter.outputImage else {
            logError("色彩钳制失败")
            return image
        }

        // 优化 1 续：显式指定 sRGB 作为输出色彩空间，由 CIContext 完成线性→sRGB 编码
        // 不再依赖手动 CILinearToSRGBToneCurve
        guard let cgImage = ciContext.createCGImage(clampedImage,
                                                    from: ciImage.extent,
                                                    format: .RGBA8,
                                                    colorSpace: sRGB) else {
            logError("CGImage 渲染失败")
            return image
        }

        logInfo("==== 真实色彩还原完成 ====")
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }

    // MARK: - 矩阵运算辅助

    private func multiplyMatrixVector(matrix: [[Double]], vector: [Double]) -> [Double] {
        return [
            matrix[0][0]*vector[0] + matrix[0][1]*vector[1] + matrix[0][2]*vector[2],
            matrix[1][0]*vector[0] + matrix[1][1]*vector[1] + matrix[1][2]*vector[2],
            matrix[2][0]*vector[0] + matrix[2][1]*vector[1] + matrix[2][2]*vector[2]
        ]
    }

    private func multiplyMatrices(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        var result = Array(repeating: Array(repeating: 0.0, count: 3), count: 3)
        for i in 0..<3 {
            for j in 0..<3 {
                for k in 0..<3 {
                    result[i][j] += a[i][k] * b[k][j]
                }
            }
        }
        return result
    }

    // MARK: - Logging

    private func logInfo(_ message: String) {
        Task { @MainActor in
            AppLogger.shared.log("[色彩还原] \(message)", isError: false)
        }
    }

    private func logError(_ message: String) {
        Task { @MainActor in
            AppLogger.shared.log("[色彩还原] ❌ \(message)", isError: true)
        }
    }
}