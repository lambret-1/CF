import Foundation
import UIKit
import CoreImage
import CoreImage.CIFilterBuiltins
import CoreLocation

final class TrueColorEngine {
    private let ciContext: CIContext
    
    init() {
        self.ciContext = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull()])
    }
    
    /// 还原真实色彩
    /// - Parameter intensity: 强度 0.0 ~ 1.0
    func restoreTrueColor(image: UIImage, captureDate: Date = Date(), location: CLLocation? = nil, intensity: CGFloat = 1.0) -> UIImage? {
        guard let ciImage = CIImage(image: image) else { return image }
        
        let timeWeights = SolarTimeHelper.getSunEventWeights(date: captureDate, location: location)
        guard let baseRGB = getAverageRGB(from: ciImage) else { return image }
        
        let warmBias = timeWeights[3] * 0.3 + timeWeights[4] * 0.4
        let targetR = baseRGB.r * (1.0 + warmBias)
        let targetG = baseRGB.g
        let targetB = baseRGB.b * (1.0 - warmBias)
        
        // 原始计算出的增益
        let rawR_Gain = targetG / max(targetR, 0.01)
        let rawG_Gain = targetG / max(targetG, 0.01)
        let rawB_Gain = targetG / max(targetB, 0.01)
        
        // ⭐️ 核心：根据强度进行插值（在 1.0 和原始增益之间）
        let rGain = 1.0 + (rawR_Gain - 1.0) * intensity
        let gGain = 1.0 + (rawG_Gain - 1.0) * intensity
        let bGain = 1.0 + (rawB_Gain - 1.0) * intensity
        
        let colorMatrix = CIFilter.colorMatrix()
        colorMatrix.inputImage = ciImage
        colorMatrix.rVector = CIVector(x: rGain, y: 0, z: 0, w: 0)
        colorMatrix.gVector = CIVector(x: 0, y: gGain, z: 0, w: 0)
        colorMatrix.bVector = CIVector(x: 0, y: 0, z: bGain, w: 0)
        colorMatrix.aVector = CIVector(x: 0, y: 0, z: 0, w: 1)
        
        guard let outputCIImage = colorMatrix.outputImage,
              let cgImage = ciContext.createCGImage(outputCIImage, from: ciImage.extent) else {
            return image
        }
        
        return UIImage(cgImage: cgImage, scale: image.scale, orientation: image.imageOrientation)
    }
    
    private func getAverageRGB(from image: CIImage) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let filter = CIFilter.areaAverage()
        filter.inputImage = image
        filter.extent = image.extent
        
        guard let outputCIImage = filter.outputImage else { return nil }
        
        var pixel = [UInt8](repeating: 0, count: 4)
        ciContext.render(outputCIImage, toBitmap: &pixel, rowBytes: 4, bounds: CGRect(x: 0, y: 0, width: 1, height: 1), format: .RGBA8, colorSpace: nil)
        
        let r = CGFloat(pixel[0]) / 255.0
        let g = CGFloat(pixel[1]) / 255.0
        let b = CGFloat(pixel[2]) / 255.0
        
        if (r + g + b) < 0.1 { return nil }
        return (r, g, b)
    }
}