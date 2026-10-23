import Foundation
import CoreML
import UIKit

// ⭐️ 去掉了 public，解决访问权限冲突
struct EngineResult {
    let image: CGImage
    let tileSize: Int
    let totalTiles: Int
}

// ⭐️ 去掉了 public，确保可以直接使用内部类型 ModelInputInfo
protocol SuperResolutionEngine: Sendable {
    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> EngineResult
}