import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import Accelerate // 引入 Accelerate 加速幂运算

final class TrueColorEngine {
    private let ciContext: CIContext
    
    init() {
        self.ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    }
    
    /// 基于 Minkowski p-范数 (p=6) 的学术标准自动白平衡
    func autoRestoreColor(image: UIImage) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return image }
        
        // 1. 缩小图像以极速分析 (保持颜色分布)
        let scaleFilter = CIFilter(name: "CILanczosScaleTransform")!
        scaleFilter.setValue(ciImage, forKey: kCIInputImageKey)
        scaleFilter.setValue(0.05, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: kCIInputAspectRatioKey)
        
        guard let smallImage = scaleFilter.outputImage else { return image }
        
        let extent = smallImage.extent
        let width = Int(extent.width)
        let height = Int(extent.height)
        guard width > 0, height > 0 else { return image }
        
        var bitmap = [UInt8](repeating: 0, count: width * height * 4)
        ciContext.render(smallImage, toBitmap: &bitmap, rowBytes: width * 4, bounds: extent, format: .RGBA8, colorSpace: nil)
        
        // 2. 学术标准：计算每个颜色通道的 Minkowski p-范数 (p=6)
        // 公式: e_i = ( (1/MN) * sum( p_i(x,y)^p ) )^(1/p)
        let p: Double = 6.0
        var sumR: Double = 0.0
        var sumG: Double = 0.0
        var sumB: Double = 0.0
        var validPixelCount: Double = 0
        
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Double(bitmap[offset]) / 255.0
            let g = Double(bitmap[offset + 1]) / 255.0
            let b = Double(bitmap[offset + 2]) / 255.0
            
            // 学术规范：忽略过曝像素 (动态范围 95% 以上)[reference:6]
            let maxChannel = max(r, max(g, b))
            if maxChannel > 0.95 { continue }
            
            // 累加 p 次幂
            sumR += pow(r, p)
            sumG += pow(g, p)
            sumB += pow(b, p)
            validPixelCount += 1.0
        }
        
        guard validPixelCount > 0 else { return image }
        
        // 计算范数 (开 p 次方根)
        let eR = pow(sumR / validPixelCount, 1.0 / p)
        let eG = pow(sumG / validPixelCount, 1.0 / p)
        let eB = pow(sumB / validPixelCount, 1.0 / p)
        
        // 3. 计算增益 (目标为中性灰，即三通道范数相等)
        // 为防止极端情况，依然保留一个宽松的钳制 (Clamp)
        let targetAvg = (eR + eG + eB) / 3.0
        
        let clamp = { (val: Double) -> Double in min(max(val, 0.4), 2.5) }
        let finalR = clamp(targetAvg / max(eR, 0.001))
        let finalG = clamp(targetAvg / max(eG, 0.001))
        let finalB = clamp(targetAvg / max(eB, 0.001))
        
        // 4. 应用到原图
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = ciImage
        colorMatrix.rVector = CIVector(x: finalR, y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: finalG, z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: finalB, w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        
        guard let outputCIImage = colorMatrix.outputImage,
              let cgImage = ciContext.createCGImage(outputCIImage, from: ciImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
}