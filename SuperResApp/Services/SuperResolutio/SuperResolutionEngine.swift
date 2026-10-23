import Foundation
import CoreML
import UIKit

// ⭐️ 新增：定义引擎返回的统一结果集
public struct EngineResult {
    public let image: CGImage
    public let tileSize: Int
    public let totalTiles: Int
    
    public init(image: CGImage, tileSize: Int, totalTiles: Int) {
        self.image = image
        self.tileSize = tileSize
        self.totalTiles = totalTiles
    }
}

// ⭐️ 标记为 Sendable，确保在 Swift Concurrency 下安全跨线程传递
public protocol SuperResolutionEngine: Sendable {
    func upscale(
        image: CGImage,
        modelID: String,
        model: MLModel,
        inputInfo: ModelInputInfo,
        scaleFactor: Int,
        progressHandler: ((InferenceProgress) -> Void)?
    ) async throws -> EngineResult // ⭐️ 返回包含统计信息的结果
}