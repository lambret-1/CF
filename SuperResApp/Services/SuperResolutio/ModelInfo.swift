import Foundation
import CoreML

struct ModelInputInfo {
    let width: Int
    let height: Int
    let isNCHW: Bool
    let isImageInput: Bool
    
    static func parse(from model: MLModel) throws -> ModelInputInfo {
        guard let inputDesc = model.modelDescription.inputDescriptionsByName.first?.value else {
            throw InferenceError.tileProcessingFailed("模型无输入描述")
        }
        
        if let imageConstraint = inputDesc.imageConstraint {
            let w = imageConstraint.pixelsWide
            let h = imageConstraint.pixelsHigh
            guard w > 0 && h > 0 else {
                throw InferenceError.tileProcessingFailed("图像输入尺寸无效(动态尺寸暂不支持): \(w)x\(h)")
            }
            return ModelInputInfo(width: w, height: h, isNCHW: false, isImageInput: true)
        }
        
        if let multiArrayConstraint = inputDesc.multiArrayConstraint {
            let rawShape = multiArrayConstraint.shape.map { $0.intValue }
            var shape = rawShape
            if shape.count == 3 {
                shape.insert(1, at: 0) // 兼容 3维
            }
            
            guard shape.count == 4 else {
                throw InferenceError.tileProcessingFailed("模型输入维度不支持 (需为 3 或 4维): \(rawShape)")
            }
            
            let c1 = shape[1]
            let c3 = shape[3]
            
            let w: Int, h: Int
            let nchw: Bool
            
            if (c1 == 1 || c1 == 3 || c1 == 4) && (c3 > 4 || c3 == c1) {
                nchw = true
                h = shape[2]
                w = shape[3]
            } else if (c3 == 1 || c3 == 3 || c3 == 4) && (c1 > 4 || c1 == c3) {
                nchw = false
                h = shape[1]
                w = shape[2]
            } else {
                throw InferenceError.tileProcessingFailed("无法推断输入格式，Shape: \(rawShape)")
            }
            
            guard w > 0 && h > 0 else {
                throw InferenceError.tileProcessingFailed("解析出的宽高无效，Shape: \(rawShape)")
            }
            
            return ModelInputInfo(width: w, height: h, isNCHW: nchw, isImageInput: false)
        }
        
        throw InferenceError.tileProcessingFailed("不支持的输入类型: \(inputDesc.type.rawValue)")
    }
}