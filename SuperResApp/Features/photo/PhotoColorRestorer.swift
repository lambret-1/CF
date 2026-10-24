import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

final class TrueColorEngine {
    private let ciContext: CIContext
    
    init() {
        self.ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    }
    
    /// 业界标准：直方图修剪 (2%) + 强度加权 + Bradford 色适应变换
    func autoRestoreColor(image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return image }
        
        // 1. 缩小图像，并转至线性 sRGB 空间进行物理级分析
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(0.05, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        
        // 先将非线性 sRGB 转为线性 sRGB（为了符合物理光学计算）
        let linearImage = scaleFilter.outputImage?.applyingFilter("CISRGBToneCurveToLinear")
        guard let smallImage = linearImage else { return image }
        
        let extent = smallImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }
        
        var bitmap = [Float](repeating: 0, count: width * height * 4)
        ciContext.render(smallImage, toBitmap: &bitmap, rowBytes: width * 4 * MemoryLayout<Float>.size, bounds: extent, format: .RGBAf, colorSpace: nil)
        
        // 2. 提取像素并计算亮度用于排序
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
            
            // 计算线性空间的相对亮度 (Luminance)
            let luma = 0.2126 * r + 0.7152 * g + 0.0722 * b
            pixels.append(Pixel(r: r, g: g, b: b, luma: luma))
        }
        
        // 3. 预处理：按亮度排序，剔除最暗和最亮的 2% (直方图修剪)
        pixels.sort { $0.luma < $1.luma }
        let trimCount = Int(Float(pixels.count) * 0.02)
        
        guard pixels.count > trimCount * 2 + 100 else { return image } // 像素太少不处理
        let validPixels = pixels[(trimCount)..<(pixels.count - trimCount)]
        
        // 4. 强度加权平均 (Intensity Weighted Average)
        var sumR: Float = 0
        var sumG: Float = 0
        var sumB: Float = 0
        var totalWeight: Float = 0
        
        for p in validPixels {
            // 亮度越高的像素，权重越大，能有效抵抗暗部噪声
            let weight = max(p.luma, 0.01) 
            sumR += p.r * weight
            sumG += p.g * weight
            sumB += p.b * weight
            totalWeight += weight
        }
        
        guard totalWeight > 0 else { return image }
        
        let srcR = Double(sumR / totalWeight)
        let srcG = Double(sumG / totalWeight)
        let srcB = Double(sumB / totalWeight)
        
        // 5. Bradford 色适应变换 (CAT)
        // 5.1 线性 sRGB 转 XYZ (D65)
        let M_sRGB2XYZ: [[Double]] = [
            [0.4124564, 0.3575761, 0.1804375],
            [0.2126729, 0.7151522, 0.0721750],
            [0.0193339, 0.1191920, 0.9503041]
        ]
        
        // 5.2 Bradford 锥体响应矩阵
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
        
        // 5.3 计算源光源的 LMS 值
        let srcXYZ = multiplyMatrixVector(matrix: M_sRGB2XYZ, vector: [srcR, srcG, srcB])
        let srcLMS = multiplyMatrixVector(matrix: M_Bradford, vector: srcXYZ)
        
        // 5.4 目标光源设定为 D65 纯白
        let dstLMS: [Double] = [0.95047, 1.0, 1.08883]
        let dstLMS_Bradford = multiplyMatrixVector(matrix: M_Bradford, vector: dstLMS)
        
        // 5.5 计算 LMS 空间的增益
        let gainL = dstLMS_Bradford[0] / max(srcLMS[0], 0.001)
        let gainM = dstLMS_Bradford[1] / max(srcLMS[1], 0.001)
        let gainS = dstLMS_Bradford[2] / max(srcLMS[2], 0.001)
        
        // 5.6 构建 LMS 增益矩阵
        let M_gain: [[Double]] = [
            [gainL, 0, 0],
            [0, gainM, 0],
            [0, 0, gainS]
        ]
        
        // 5.7 构建 XYZ 转线性 sRGB 矩阵
        let M_XYZ2sRGB: [[Double]] = [
            [ 3.2404542, -1.5371385, -0.4985314],
            [-0.9692660,  1.8760108,  0.0415560],
            [ 0.0556434, -0.2040259,  1.0572252]
        ]
        
        // 5.8 计算最终的 3x3 转换矩阵
        // final = XYZ2sRGB * BradfordInv * M_gain * Bradford * sRGB2XYZ
        let step1 = multiplyMatrices(M_Bradford, M_sRGB2XYZ)
        let step2 = multiplyMatrices(M_gain, step1)
        let step3 = multiplyMatrices(M_BradfordInv, step2)
        let M_final = multiplyMatrices(M_XYZ2sRGB, step3)
        
        // 6. 应用到原图
        // sRGB -> 线性 sRGB -> 应用 3x3 矩阵 -> 回到 sRGB
        let linearOriginal = ciImage.applyingFilter("CISRGBToneCurveToLinear")
        
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = linearOriginal
        
        // 注意：CIColorMatrix 的 rVector 代表输出 R 是如何由输入的 R,G,B 组成的
        colorMatrix.rVector = CIVector(x: M_final[0][0], y: M_final[0][1], z: M_final[0][2], w: 0)
        colorMatrix.gVector = CIVector(x: M_final[1][0], y: M_final[1][1], z: M_final[1][2], w: 0)
        colorMatrix.bVector = CIVector(x: M_final[2][0], y: M_final[2][1], z: M_final[2][2], w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        
        guard let outputLinear = colorMatrix.outputImage else { return image }
        let outputSRGB = outputLinear.applyingFilter("CILinearToSRGBToneCurve")
        
        guard let cgImage = ciContext.createCGImage(outputSRGB, from: ciImage.extent) else {
            return image
        }
        
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
}