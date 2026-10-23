import Foundation
import CoreML

/// 解析模型输入约束的结构体
struct ModelInputInfo {
    let width: Int
    let height: Int
    let isNCHW: Bool
    let isImageInput: Bool
    
    static func parse(from model: MLModel) throws -> ModelInputInfo {
        guard let inputDesc = model.modelDescription.inputDescriptionsByName.first?.value else {
            throw InferenceError.tileProcessingFailed("模型无输入描述")
        }
        
        // 1. 处理 Image 类型的输入约束
        if let imageConstraint = inputDesc.imageConstraint {
            let w = imageConstraint.pixelsWide
            let h = imageConstraint.pixelsHigh
            guard w > 0 && h > 0 else {
                throw InferenceError.tileProcessingFailed("图像输入尺寸无效(动态尺寸暂不支持): \(w)x\(h)")
            }
            return ModelInputInfo(width: w, height: h, isNCHW: false, isImageInput: true)
        }
        
        // 2. 处理 MultiArray 类型的输入约束
        if let multiArrayConstraint = inputDesc.multiArrayConstraint {
            let rawShape = multiArrayConstraint.shape.map { $0.intValue }
            
            // ⭐️ 兼容 3 维 [C, H, W] 的情况，自动补一个 batch 维度
            var shape = rawShape
            if shape.count == 3 {
                shape.insert(1, at: 0) // 变成 [1, C, H, W]
            }
            
            guard shape.count == 4 else {
                throw InferenceError.tileProcessingFailed("模型输入维度不支持 (需为 3 或 4维): \(rawShape)")
            }
            
            // ⭐️ 修复 1 & 4：更聪明地判断 NCHW 与 NHWC
            // 利用通道数通常较小(1,3,4)，而宽高通常较大的特性
            let c1 = shape[1]
            let c3 = shape[3]
            
            let w: Int, h: Int
            let nchw: Bool
            
            if (c1 == 1 || c1 == 3 || c1 == 4) && (c3 > 4 || c3 == c1) {
                // 典型 NCHW: [B, 3, H, W]
                nchw = true
                h = shape[2]
                w = shape[3]
            } else if (c3 == 1 || c3 == 3 || c3 == 4) && (c1 > 4 || c1 == c3) {
                // 典型 NHWC: [B, H, W, 3]
                nchw = false
                h = shape[1]
                w = shape[2]
            } else {
                throw InferenceError.tileProcessingFailed("无法推断输入格式，Shape: \(rawShape)")
            }
            
            // ⭐️ 修复 2：拦截动态尺寸（0 或 -1）
            guard w > 0 && h > 0 else {
                throw InferenceError.tileProcessingFailed("解析出的宽高无效(可能是动态尺寸模型)，W:\(w) H:\(h)，Shape: \(rawShape)")
            }
            
            return ModelInputInfo(width: w, height: h, isNCHW: nchw, isImageInput: false)
        }
        
        throw InferenceError.tileProcessingFailed("不支持的输入类型: \(inputDesc.type.rawValue)")
    }
}