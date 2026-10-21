// SuperResApp/Models/ModelDescriptor.swift
// 模型描述符：计算单元映射、缩放倍数、分块参数等运行时配置

import CoreML
import Foundation

/// 模型描述符，包含模型推理所需的运行时配置
struct ModelDescriptor {
    /// 模型 id
    let id: String
    /// 显示名称
    let name: String
    /// 缩放倍数（2x / 4x）
    let scaleFactor: Int
    /// 主计算单元
    let primaryComputeUnits: MLComputeUnits
    /// SinSR 专用：Denoiser 的计算单元（必须 .cpuOnly）
    let denoiserComputeUnits: MLComputeUnits?
    /// 是否为 SinSR 三件套模型
    let isSinSR: Bool
    /// 默认分块大小
    let defaultTileSize: Int
    /// 降级分块大小
    let fallbackTileSize: Int
    /// 分块重叠像素（输入域）
    let overlapPixels: Int
    /// 是否支持实时预览
    let supportsLivePreview: Bool

    /// 根据清单条目创建描述符
    static func descriptor(for item: ModelManifestItem) -> ModelDescriptor {
        switch item.id {
        case "piper-sr-2x":
            return ModelDescriptor(
                id: item.id,
                name: item.name,
                scaleFactor: 2,
                primaryComputeUnits: .cpuAndNeuralEngine,
                denoiserComputeUnits: nil,
                isSinSR: false,
                defaultTileSize: 512,
                fallbackTileSize: 256,
                overlapPixels: 16,
                supportsLivePreview: true
            )
        case "realesrgan-x4v3", "realesrgan-x4", "realesrgan-x4plus", "realesrgan-ultrasharp":
            return ModelDescriptor(
                id: item.id,
                name: item.name,
                scaleFactor: 4,
                primaryComputeUnits: .all,
                denoiserComputeUnits: nil,
                isSinSR: false,
                defaultTileSize: 512,
                fallbackTileSize: 256,
                overlapPixels: 16,
                supportsLivePreview: false
            )
        case "sinsr":
            return ModelDescriptor(
                id: item.id,
                name: item.name,
                scaleFactor: 4,
                primaryComputeUnits: .all,
                denoiserComputeUnits: .cpuOnly,
                isSinSR: true,
                defaultTileSize: 128,
                fallbackTileSize: 64,
                overlapPixels: 16,
                supportsLivePreview: false
            )
        default:
            return ModelDescriptor(
                id: item.id,
                name: item.name,
                scaleFactor: 4,
                primaryComputeUnits: .all,
                denoiserComputeUnits: nil,
                isSinSR: false,
                defaultTileSize: 512,
                fallbackTileSize: 256,
                overlapPixels: 16,
                supportsLivePreview: false
            )
        }
    }

    /// 输出域的重叠像素（输入 overlap × 缩放倍数）
    var outputOverlapPixels: Int {
        overlapPixels * scaleFactor
    }

    /// 将字符串计算单元映射为 MLComputeUnits
    static func computeUnits(from string: String) -> MLComputeUnits {
        switch string.lowercased() {
        case "cpuandneuralengine", "cpu_and_neural_engine":
            return .cpuAndNeuralEngine
        case "cpuonly", "cpu_only":
            return .cpuOnly
        case "cpuandgpu", "cpu_and_gpu":
            return .cpuAndGPU
        case "all":
            return .all
        default:
            return .all
        }
    }
}

// MARK: - 推理进度信息

/// 推理进度回调信息
struct InferenceProgress {
    /// 当前处理的块索引（从 1 开始）
    let currentTile: Int
    /// 总块数
    let totalTiles: Int
    /// 整体进度 0.0 - 1.0
    let fraction: Double
    /// 已用时间（秒）
    let elapsedSeconds: TimeInterval
    /// 预计剩余时间（秒），nil 表示无法估算
    let estimatedRemainingSeconds: TimeInterval?

    /// 格式化的进度文本
    var progressText: String {
        "处理中 \(currentTile)/\(totalTiles) 块"
    }

    /// 格式化的预计剩余时间
    var remainingText: String? {
        guard let remaining = estimatedRemainingSeconds, remaining > 0 else { return nil }
        if remaining < 60 {
            return String(format: "预计剩余 %.0f 秒", remaining)
        } else {
            let minutes = Int(remaining) / 60
            let seconds = Int(remaining) % 60
            return String(format: "预计剩余 %d 分 %d 秒", minutes, seconds)
        }
    }
}

// MARK: - 推理结果

/// 推理结果
struct InferenceResult {
    /// 超分后的图片
    let outputImage: CGImage
    /// 输入尺寸
    let inputSize: CGSize
    /// 输出尺寸
    let outputSize: CGSize
    /// 处理耗时（秒）
    let elapsedSeconds: TimeInterval
    /// 使用的模型 id
    let modelID: String
    /// 实际使用的分块大小
    let tileSize: Int
    /// 总块数
    let totalTiles: Int
}

// MARK: - 推理错误

enum InferenceError: LocalizedError {
    case modelNotLoaded(String)
    case invalidInputImage
    case insufficientMemory
    case tileProcessingFailed(String)
    case outputCreationFailed
    case cancelled
    case modelCompilationFailed(String)

    var errorDescription: String? {
        switch self {
        case .modelNotLoaded(let id):
            return "模型未加载：\(id)"
        case .invalidInputImage:
            return "输入图片无效"
        case .insufficientMemory:
            return "内存不足，请尝试更小分块"
        case .tileProcessingFailed(let detail):
            return "分块处理失败：\(detail)"
        case .outputCreationFailed:
            return "输出图片创建失败"
        case .cancelled:
            return "推理已取消"
        case .modelCompilationFailed(let detail):
            return "模型编译失败：\(detail)"
        }
    }

    /// 是否可以通过降低分块大小重试
    var canRetryWithSmallerTile: Bool {
        switch self {
        case .insufficientMemory, .tileProcessingFailed:
            return true
        default:
            return false
        }
    }
}
