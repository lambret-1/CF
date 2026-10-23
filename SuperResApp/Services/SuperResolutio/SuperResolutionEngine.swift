// SuperResApp/Services/SuperResolutio/Engines/SuperResolutionEngine.swift

import Foundation
import CoreML
import UIKit

/// 超分处理引擎协议，所有模型处理策略都必须遵守此协议
protocol SuperResolutionEngine {
    /// 执行图片超分
    func upscale(
        image: CGImage,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> CGImage
}