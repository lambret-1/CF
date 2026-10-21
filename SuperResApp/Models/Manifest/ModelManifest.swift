// SuperResApp/Models/Manifest/ModelManifest.swift
// 模型清单数据结构与状态枚举

import Foundation

// MARK: - 模型清单条目

/// 模型清单条目，对应 model_manifest.json 中的每一项
struct ModelManifestItem: Codable, Identifiable, Hashable {
    /// 模型唯一标识，如 "piper-sr-2x"
    let id: String
    /// 显示名称，如 "PiperSR 2x (ANE)"
    let name: String
    /// 模型体积（字节）
    let size: Int64
    /// 下载地址（zip 包），内置模型可为空
    let url: String
    /// SHA256 校验值，留空表示不校验
    let sha256: String
    /// 是否为内置模型
    let builtin: Bool
    /// 是否仅 Wi-Fi 下载
    let wifiOnly: Bool
    /// 计算单元字符串："all" / "cpuAndNeuralEngine" / "mixed"
    let computeUnits: String
    /// 许可证名称
    let license: String
    /// 模型来源链接
    let source: String
    /// 备注信息
    let note: String?

    enum CodingKeys: String, CodingKey {
        case id, name, size, url, sha256, builtin, wifiOnly
        case computeUnits, license, source, note
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decode(String.self, forKey: .name)
        size = try container.decode(Int64.self, forKey: .size)
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        sha256 = try container.decodeIfPresent(String.self, forKey: .sha256) ?? ""
        builtin = try container.decodeIfPresent(Bool.self, forKey: .builtin) ?? false
        wifiOnly = try container.decodeIfPresent(Bool.self, forKey: .wifiOnly) ?? false
        computeUnits = try container.decodeIfPresent(String.self, forKey: .computeUnits) ?? "all"
        license = try container.decodeIfPresent(String.self, forKey: .license) ?? "未知"
        source = try container.decodeIfPresent(String.self, forKey: .source) ?? ""
        note = try container.decodeIfPresent(String.self, forKey: .note)
    }
}

// MARK: - 模型运行时状态

/// 模型在本地的运行时状态
enum ModelStatus: String, Codable {
    /// 内置模型，开箱即用
    case builtin = "内置"
    /// 未下载
    case notDownloaded = "未下载"
    /// 排队中
    case queued = "排队中"
    /// 下载中
    case downloading = "下载中"
    /// 已暂停
    case paused = "已暂停"
    /// 编译中
    case compiling = "编译中"
    /// 已下载可用
    case downloaded = "已下载"
    /// 失败
    case failed = "失败"
}

// MARK: - 模型运行时信息（清单 + 状态 + 下载进度）

/// 模型运行时信息，组合清单条目与当前状态
struct ModelRuntimeInfo: Identifiable, Hashable {
    let id: String
    let manifest: ModelManifestItem
    var status: ModelStatus
    /// 下载进度 0.0 - 1.0
    var downloadProgress: Double
    /// 已下载字节数
    var downloadedBytes: Int64
    /// 失败原因描述
    var failureReason: String?

    var name: String { manifest.name }
    var size: Int64 { manifest.size }
    var isBuiltin: Bool { manifest.builtin }
    var wifiOnly: Bool { manifest.wifiOnly }
    var license: String { manifest.license }
    var computeUnits: String { manifest.computeUnits }
    var source: String { manifest.source }
    var note: String? { manifest.note }
    var downloadURL: String { manifest.url }
    var sha256: String { manifest.sha256 }

    /// 是否为非商用模型
    var isNonCommercial: Bool {
        license.contains("NC") || license.contains("非商用") || license.contains("BY-NC")
    }

    /// 是否需要标注 CPU 较慢
    var isCPUSlow: Bool {
        id == "sinsr" || computeUnits == "mixed"
    }

    /// 格式化体积显示
    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
    }

    /// 格式化已下载体积
    var formattedDownloaded: String {
        ByteCountFormatter.string(fromByteCount: downloadedBytes, countStyle: .file)
    }
}

// MARK: - 下载队列持久化模型

/// 下载队列持久化条目
struct DownloadQueueItem: Codable, Identifiable, Hashable {
    let id: String
    /// 恢复下载的数据（断点续传）
    var resumeData: Data?
    /// 已下载字节数
    var downloadedBytes: Int64
    /// 排队时间
    let queuedAt: Date
    /// 是否暂停
    var isPaused: Bool
}
