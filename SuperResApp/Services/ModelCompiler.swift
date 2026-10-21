// SuperResApp/Services/ModelCompiler.swift
// 模型编译器：解压 zip → 找到 .mlpackage → 编译为 .mlmodelc → 移动到 Application Support

import Foundation
import CoreML
import ZIPFoundation

/// 模型编译器，负责将下载的 zip 包编译为可加载的 .mlmodelc
actor ModelCompiler {
    /// 单例
    static let shared = ModelCompiler()

    private let manifestLoader = ModelManifestLoader.shared

    /// 编译回调
    typealias CompileProgressHandler = (String) -> Void

    private init() {}

    // MARK: - 编译模型

    /// 编译下载的模型 zip 包
    /// - Parameters:
    ///   - modelID: 模型 id
    ///   - zipURL: zip 文件路径
    /// - Returns: 编译后的 .mlmodelc 路径
    func compile(modelID: String, zipURL: URL) async throws -> URL {
        await manifestLoader.updateStatus(.compiling, for: modelID)

        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("SuperResCompile_\(modelID)", isDirectory: true)

        // 清理旧的临时目录
        try? fileManager.removeItem(at: tempDir)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            // 清理临时文件
            try? fileManager.removeItem(at: tempDir)
            try? fileManager.removeItem(at: zipURL)
        }

        // 1. 解压 zip
        do {
            try fileManager.unzipItem(at: zipURL, to: tempDir)
        } catch {
            await manifestLoader.markFailed(id: modelID, reason: "解压失败：\(error.localizedDescription)")
            throw CompileError.unzipFailed(error.localizedDescription)
        }

        // 2. 查找 .mlpackage 目录
        guard let packageURL = try findMLPackage(in: tempDir, modelID: modelID) else {
            await manifestLoader.markFailed(id: modelID, reason: "未找到 .mlpackage 目录")
            throw CompileError.packageNotFound
        }

        // 3. 编译模型
        let compiledURL: URL
        do {
            compiledURL = try MLModel.compileModel(at: packageURL)
        } catch {
            await manifestLoader.markFailed(id: modelID, reason: "编译失败：\(error.localizedDescription)")
            throw CompileError.compileFailed(error.localizedDescription)
        }

        // 4. 移动到 Application Support/Models/
        let destination = await manifestLoader.compiledModelURL(for: modelID)
        let destDir = destination.deletingLastPathComponent()
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        // 如果目标已存在，先删除
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.moveItem(at: compiledURL, to: destination)
        } catch {
            // move 失败时尝试 copy
            try fileManager.copyItem(at: compiledURL, to: destination)
        }

        await manifestLoader.updateStatus(.downloaded, for: modelID)
        return destination
    }

    // MARK: - SinSR 三件套特殊处理

    /// 编译 SinSR 三件套（Encoder/Decoder/Denoiser）
    /// - Parameters:
    ///   - zipURL: 包含三个子模型的 zip
    /// - Returns: 三个子模型的编译后路径
    func compileSinSRBundle(zipURL: URL) async throws -> (encoder: URL, decoder: URL, denoiser: URL) {
        let fileManager = FileManager.default
        let tempDir = fileManager.temporaryDirectory
            .appendingPathComponent("SuperResCompile_sinsr", isDirectory: true)

        try? fileManager.removeItem(at: tempDir)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
            try? fileManager.removeItem(at: zipURL)
        }

        // 解压
        do {
            try fileManager.unzipItem(at: zipURL, to: tempDir)
        } catch {
            throw CompileError.unzipFailed(error.localizedDescription)
        }

        // 查找三个子模型
        guard let encoderPackage = findSubmodelPackage(in: tempDir, keyword: "Encoder"),
              let decoderPackage = findSubmodelPackage(in: tempDir, keyword: "Decoder"),
              let denoiserPackage = findSubmodelPackage(in: tempDir, keyword: "Denoiser") else {
            throw CompileError.sinSRSubmodelNotFound
        }

        // 编译三个子模型
        let encoderCompiled = try MLModel.compileModel(at: encoderPackage)
        let decoderCompiled = try MLModel.compileModel(at: decoderPackage)
        let denoiserCompiled = try MLModel.compileModel(at: denoiserPackage)

        // 移动到目标目录
        let modelsDir = await manifestLoader.compiledModelURL(for: "sinsr").deletingLastPathComponent()
        try? fileManager.createDirectory(at: modelsDir, withIntermediateDirectories: true)

        let encoderDest = modelsDir.appendingPathComponent("sinsr_encoder.mlmodelc")
        let decoderDest = modelsDir.appendingPathComponent("sinsr_decoder.mlmodelc")
        let denoiserDest = modelsDir.appendingPathComponent("sinsr_denoiser.mlmodelc")

        for (src, dest) in [(encoderCompiled, encoderDest), (decoderCompiled, decoderDest), (denoiserCompiled, denoiserDest)] {
            if fileManager.fileExists(atPath: dest.path) {
                try fileManager.removeItem(at: dest)
            }
            try fileManager.moveItem(at: src, to: dest)
        }

        await manifestLoader.updateStatus(.downloaded, for: "sinsr")
        return (encoderDest, decoderDest, denoiserDest)
    }

    // MARK: - 删除模型

    /// 删除已编译的模型
    func delete(modelID: String) async throws {
        let destination = await manifestLoader.compiledModelURL(for: modelID)
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        // SinSR 需要额外删除子模型
        if modelID == "sinsr" {
            let modelsDir = destination.deletingLastPathComponent()
            for submodel in ["sinsr_encoder", "sinsr_decoder", "sinsr_denoiser"] {
                let subURL = modelsDir.appendingPathComponent("\(submodel).mlmodelc")
                try? fileManager.removeItem(at: subURL)
            }
        }
        await manifestLoader.updateStatus(.notDownloaded, for: modelID)
        await manifestLoader.updateProgress(0, downloadedBytes: 0, for: modelID)
    }

    // MARK: - 私有方法

    /// 在目录中递归查找 .mlpackage
    private func findMLPackage(in directory: URL, modelID: String) throws -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        var packages: [URL] = []
        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "mlpackage" {
                packages.append(fileURL)
            }
        }

        if packages.isEmpty { return nil }

        // 优先匹配模型 id
        if let match = packages.first(where: {
            $0.lastPathComponent.lowercased().contains(modelID.lowercased())
        }) {
            return match
        }

        return packages.first
    }

    /// 查找 SinSR 子模型包
    private func findSubmodelPackage(in directory: URL, keyword: String) -> URL? {
        let fileManager = FileManager.default
        guard let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }

        for case let fileURL as URL in enumerator {
            if fileURL.pathExtension == "mlpackage",
               fileURL.lastPathComponent.lowercased().contains(keyword.lowercased()) {
                return fileURL
            }
        }
        return nil
    }
}

// MARK: - 编译错误

enum CompileError: LocalizedError {
    case unzipFailed(String)
    case packageNotFound
    case compileFailed(String)
    case moveFailed(String)
    case sinSRSubmodelNotFound

    var errorDescription: String? {
        switch self {
        case .unzipFailed(let detail):
            return "解压失败：\(detail)"
        case .packageNotFound:
            return "未找到 .mlpackage 目录"
        case .compileFailed(let detail):
            return "模型编译失败：\(detail)"
        case .moveFailed(let detail):
            return "文件移动失败：\(detail)"
        case .sinSRSubmodelNotFound:
            return "未找到 SinSR 子模型（Encoder/Decoder/Denoiser）"
        }
    }
}
