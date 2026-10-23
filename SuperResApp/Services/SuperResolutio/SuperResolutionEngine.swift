// SuperResApp/Services/SuperResolutio/Engines/SuperResolutionEngine.swift

import Foundation
import CoreML
import UIKit

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