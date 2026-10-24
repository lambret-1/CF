import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins

final class TrueColorEngine {
    private let ciContext: CIContext
    
    init() {
        self.ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
 return    }
    
    /// 极致一键：自动 image融合“白块”与“灰世界”算法
    func auto }
        
RestoreColor(image: UIImage) ->        UIImage? {
        guard let ciImage = CIImage(image //: image) else { 1. 缩小图像以极速分析（不损失准确率）
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
        
        // 2. 开始双算法混合计算
        var whitePatchR: Double = 0, whitePatchG: Double = 0, whitePatchB: Double = 0, whiteCount: Double = 0
        var grayWorldR: Double = 0, grayWorldG: Double = 0, grayWorldB: Double = 0, grayWeight: Double = 0
        
        for i in 0..<(width * height) {
            let offset = i * 4
            let r = Double(bitmap[offset]) / 255.0
            let g = Double(bitmap[offset + 1]) / 255.0
            let b = Double(bitmap[offset + 2]) / 255.0
            
            let maxChannel = max(r, max(g, b))
            let minChannel = min(r, min(g, b))
            
            // 【白块算法】寻找高光点 (亮度在 0.7 ~ 0.95 之间，避开纯白过曝)
            if maxChannel > 0.7 && maxChannel < 0.95 {
                whitePatchR += r
                whitePatchG += g
                whitePatchB += b
                whiteCount += 1
            }
            
            // 【灰世界算法】寻找中间调 (亮度在 0.15 ~ 0.9 之间)
            if maxChannel >= 0.15 && maxChannel <= 0.9 {
                // 计算饱和度，饱和度越高的物体（如红花），越不参与计算，防止被洗灰
                let saturation = maxChannel == 0 ? 0 : (maxChannel - minChannel) / maxChannel
                let weight = 1.0 - (saturation * 0.7) 
                
                grayWorldR += r * weight
                grayWorldG += g * weight
                grayWorldB += b * weight
                grayWeight += weight
            }
        }
        
        // 3. 计算最终需要的 RGB 增益
        var targetR: Double = 1.0
        var targetG: Double = 1.0
        var targetB: Double = 1.0
        
        if whiteCount > (Double(width * height) * 0.01) {
            // 如果画面中有超过 1% 的高光区域，优先使用白块算法（对偏黄偏蓝极其有效）
            let avgWPR = whitePatchR / whiteCount
            let avgWPG = whitePatchG / whiteCount
            let avgWPB = whitePatchB / whiteCount
            
            // 目标是纯白
            targetR = 1.0 / max(avgWPR, 0.01)
            targetG = 1.0 / max(avgWPG, 0.01)
            targetB = 1.0 / max(avgWPB, 0.01)
        } else if grayWeight > 0 {
            // 如果没有明显高光（如夜景、森林），降级使用智能灰世界
            let avgGWR = grayWorldR / grayWeight
            let avgGWG = grayWorldG / grayWeight
            let avgGWB = grayWorldB / grayWeight
            let targetAvg = (avgGWR + avgGWG + avgGWB) / 3.0
            
            targetR = targetAvg / max(avgGWR, 0.01)
            targetG = targetAvg / max(avgGWG, 0.01)
            targetB = targetAvg / max(avgGWB, 0.01)
        } else {
            return image // 极端情况（全黑），直接返回原图
        }
        
        // 限制最大增益，防止暴力拉偏颜色
        let clamp = { (val: Double) -> Double in min(max(val, 0.5), 2.0) }
        let finalR = clamp(targetR)
        let finalG = clamp(targetG)
        let finalB = clamp(targetB)
        
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