import Foundation
import CoreML
import UIKit

// 移除多出来的 EngineResult，直接返回图片即可
protocol SuperResolutionEngine {
    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> CGImage
}