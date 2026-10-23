import Foundation
import CoreML
import UIKit

// ⭐️ 去掉 public
struct EngineResult {
    let image: CGImage
    let tileSize: Int
    let totalTiles: Int
}

// ⭐️ 去掉 public
protocol SuperResolutionEngine: Sendable {
    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> EngineResult // 返回 EngineResult
}