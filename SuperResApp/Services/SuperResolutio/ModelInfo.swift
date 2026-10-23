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
            throw InferenceError.tileProcessingFailed("模型无输入")
        }
        
        if let imageConstraint = inputDesc.imageConstraint {
            return ModelInputInfo(
                width: imageConstraint.pixelsWide,
                height: imageConstraint.pixelsHigh,
                isNCHW: false,
                isImageInput: true
            )
        } else if let multiArrayConstraint = inputDesc.multiArrayConstraint {
            let shape = multiArrayConstraint.shape.map { $0.intValue }
            guard shape.count == 4 else {
                throw InferenceError.tileProcessingFailed("模型输入维度不是 4")
            }
            
            var w = 0, h = 0
            var nchw = false
            if shape[1] == 3 { // NCHW
                h = shape[2]; w = shape[3]; nchw = true
            } else if shape[3] == 3 { // NHWC
                h = shape[1]; w = shape[2]; nchw = false
            } else {
                throw InferenceError.tileProcessingFailed("未知的模型输入形状")
            }
            
            return ModelInputInfo(width: w, height: h, isNCHW: nchw, isImageInput: false)
        } else {
            throw InferenceError.tileProcessingFailed("不支持的输入类型")
        }
    }
}