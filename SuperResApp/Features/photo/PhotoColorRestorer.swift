import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

final class PhotoColorRestorer {
    private let ciContext: CIContext
    private let linearSRGB: CGColorSpace
    private let sRGB: CGColorSpace

    // 修复 #5：改用可失败初始化，避免在工具类中 fatalError
    init?() {
        guard let linear = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
              let srgb = CGColorSpace(name: CGColorSpace.sRGB) else {
            return nil
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
        // 修复 #5：使用 typed filter 替代 CIFilter(name:)! 强制解包
        let scaleFilter = CIFilter.lanczosScaleTransform()
        scaleFilter.inputImage = ciImage
        scaleFilter.scale = 0.05
        scaleFilter.aspectRatio = 1.0

        guard let smallImage = scaleFilter.outputImage else {
            logError("图像缩放失败")
            return image
        }

        // 修复 #4：extent 取整，避免 bitmap 分配尺寸与 render bounds 不匹配
        // 导致的越界写/渲染错位
        let extent = smallImage.extent.integral
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else {
            logError("分析图像尺寸无效")
            return image
        }

        logInfo("分析采样尺寸: \(width)x\(height) (线性空间)")

        var bitmap = [Float](repeating: 0, count: width * height * 4)
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

        // 修复 #3：读取 alpha 通道，过滤半透明/透明像素
        // CIImage 内部为 premultiplied alpha，半透明像素 RGB 会被 alpha 压低，
        // 直接进入统计会拉低光源估计。此处仅保留 alpha >= 0.5 的像素。
        var skippedAlpha = 0
        for i in 0..<(width * height) {
            let offset = i * 4
            let a = bitmap[offset + 3]
            guard a >= 0.5 else {
                skippedAlpha += 1
                continue
            }
            let r = bitmap[offset]
            let g = bitmap[offset + 1]
            let b = bitmap[offset + 2]
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            pixels.append(Pixel(r: r, g: g, b: b, luma: luma))
        }
        if skippedAlpha > 0 {
            logInfo("已过滤 \(skippedAlpha) 个半透明/透明像素")
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

        var fallbackSumR: Float = 0
        var fallbackSumG: Float = 0
        var fallbackSumB: Float = 0
        var fallbackWeight: Float = 0

        let neutralSigma: Float = 0.25
        let neutralSigma2 = 2 * neutralSigma * neutralSigma
        let highlightStart: Float = 0.85
        let highlightEnd: Float = 1.0

        for p in validPixels {
            let lumaWeight = max(p.luma, 0.01)

            let maxC = max(p.r, max(p.g, p.b))
            let minC = min(p.r, min(p.g, p.b))
            let denom = max(maxC, 1e-6)
            let saturation = (maxC - minC) / denom
            let neutralWeight = exp(-(saturation * saturation) / neutralSigma2)

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

        // 修复 #1：将估计光源的 XYZ 归一化到 Y=1。
        // 原始 srcXYZ 的 Y 分量通常远小于 1（如中性灰卡 Y≈0.18），
        // 而参考白 D65 的 Y=1。若不归一化，gain ≈ 1/Y，导致整图被放大若干倍而严重过曝。
        let srcXYZ_raw = multiplyMatrixVector(matrix: M_sRGB2XYZ, vector: [srcR, srcG, srcB])
        let ySrc = max(srcXYZ_raw[1], 1e-6)
        let srcXYZ = srcXYZ_raw.map { $0 / ySrc }
        let srcLMS = multiplyMatrixVector(matrix: M_Bradford, vector: srcXYZ)

        // 修复 #2（前置于增益计算）：LMS 通道异常检测。
        // 归一化后 LMS 应全为正；若出现负值或接近 0，说明光源估计失败，
        // 直接算增益会得到天文数字，整图崩坏。
        guard srcLMS.allSatisfy({ $0.isFinite && $0 > 1e-6 }) else {
            logError(String(format: "估计光源 LMS 异常: L=%.6f, M=%.6f, S=%.6f，放弃还原",
                            srcLMS[0], srcLMS[1], srcLMS[2]))
            return image
        }

        // D65 参考白
        let dstLMS: [Double] = [0.95047, 1.0, 1.08883]
        let dstLMS_Bradford = multiplyMatrixVector(matrix: M_Bradford, vector: dstLMS)

        // 修复 #2：对 LMS 增益做钳制，防止极端色偏 / 极端场景下增益爆炸。
        // 正常白平衡增益大致落在 [0.5, 2.0]，这里放宽到 [0.25, 4.0]。
        let gainL = clamped(dstLMS_Bradford[0] / srcLMS[0], 0.25, 4.0)
        let gainM = clamped(dstLMS_Bradford[1] / srcLMS[1], 0.25, 4.0)
        let gainS = clamped(dstLMS_Bradford[2] / srcLMS[2], 0.25, 4.0)
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

        // 5. 应用矩阵（在线性工作空间运算）
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

        // 钳制到 [0, 1]
        let clampFilter = CIFilter.colorClamp()
        clampFilter.inputImage = matrixOutput
        clampFilter.minComponents = CIVector(x: 0, y: 0, z: 0, w: 0)
        clampFilter.maxComponents = CIVector(x: 1, y: 1, z: 1, w: 1)

        guard let clampedImage = clampFilter.outputImage else {
            logError("色彩钳制失败")
            return image
        }

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

    // MARK: - 辅助

    private func clamped(_ value: Double, _ lower: Double, _ upper: Double) -> Double {
        return min(max(value, lower), upper)
    }

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