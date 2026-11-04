// SuperResApp/Services/ModelCompiler.swift
// 模型安装器：解压 ZIP，安装预编译 .mlmodelc 或编译 .mlpackage

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
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        
        // ⭐️ 编译临时目录放到 Application Support 下，彻底避开 tmp 权限和清理问题
        let modelsDir = paths[0].appendingPathComponent("Models", isDirectory: true)
        let compileTempRoot = modelsDir.appendingPathComponent("CompileTemp", isDirectory: true)
        let tempDir = compileTempRoot.appendingPathComponent(modelID, isDirectory: true)

        // 清理旧的临时目录并重新创建
        try? fileManager.removeItem(at: tempDir)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            // 编译结束后清理临时文件
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

        // 2. 优先识别预编译 .mlmodelc（RIFE Release 提供预编译模型）。
        //    ZIP 有时只包含 .mlmodelc 内部文件，而没有保留外层目录名；
        //    因此同时按 Core ML 编译产物特征识别，不能只依赖扩展名。
        let compiledURL: URL
        if let precompiledURL = findCompiledModel(in: tempDir, modelID: modelID) {
            compiledURL = precompiledURL
        } else {
            guard let packageURL = try findMLPackage(in: tempDir, modelID: modelID) else {
                let contents = extractedContentsSummary(in: tempDir)
                let reason = "解压成功，但未识别到 Core ML 模型目录。解压内容：\(contents)"
                await manifestLoader.markFailed(id: modelID, reason: reason)
                throw CompileError.packageNotFound
            }
            do {
                compiledURL = try await MLModel.compileModel(at: packageURL)
            } catch {
                await manifestLoader.markFailed(id: modelID, reason: "编译失败：\(error.localizedDescription)")
                throw CompileError.compileFailed(error.localizedDescription)
            }
        }

        // 4. 移动到 Application Support/Models/
        let destination = await manifestLoader.compiledModelURL(for: modelID)
        let destDir = destination.deletingLastPathComponent()
        
        // 确保目标父目录绝对存在
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.moveItem(at: compiledURL, to: destination)
        } catch {
            // 如果 move 失败，尝试 copy 兜底
            try fileManager.copyItem(at: compiledURL, to: destination)
        }

        await manifestLoader.updateStatus(.downloaded, for: modelID)
        return destination
    }

    // MARK: - SinSR 三件套特殊处理

    /// 编译 SinSR 三件套（Encoder/Decoder/Denoiser）
    func compileSinSRBundle(zipURL: URL) async throws -> (encoder: URL, decoder: URL, denoiser: URL) {
        let fileManager = FileManager.default
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        
        // ⭐️ 同样迁移到 Application Support
        let modelsDir = paths[0].appendingPathComponent("Models", isDirectory: true)
        let compileTempRoot = modelsDir.appendingPathComponent("CompileTemp", isDirectory: true)
        let tempDir = compileTempRoot.appendingPathComponent("sinsr", isDirectory: true)

        try? fileManager.removeItem(at: tempDir)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
            try? fileManager.removeItem(at: zipURL)
        }

        do {
            try fileManager.unzipItem(at: zipURL, to: tempDir)
        } catch {
            throw CompileError.unzipFailed(error.localizedDescription)
        }

        guard let encoderPackage = findSubmodelPackage(in: tempDir, keyword: "Encoder"),
              let decoderPackage = findSubmodelPackage(in: tempDir, keyword: "Decoder"),
              let denoiserPackage = findSubmodelPackage(in: tempDir, keyword: "Denoiser") else {
            throw CompileError.sinSRSubmodelNotFound
        }

        let encoderCompiled = try await MLModel.compileModel(at: encoderPackage)
        let decoderCompiled = try await MLModel.compileModel(at: decoderPackage)
        let denoiserCompiled = try await MLModel.compileModel(at: denoiserPackage)

        let destModelsDir = await manifestLoader.compiledModelURL(for: "sinsr").deletingLastPathComponent()
        try? fileManager.createDirectory(at: destModelsDir, withIntermediateDirectories: true)

        let encoderDest = destModelsDir.appendingPathComponent("sinsr_encoder.mlmodelc")
        let decoderDest = destModelsDir.appendingPathComponent("sinsr_decoder.mlmodelc")
        let denoiserDest = destModelsDir.appendingPathComponent("sinsr_denoiser.mlmodelc")

        for (src, dest) in [(encoderCompiled, encoderDest), (decoderCompiled, decoderDest), (denoiserCompiled, denoiserDest)] {
            if fileManager.fileExists(atPath: dest.path) {
                try? fileManager.removeItem(at: dest)
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

    /// 查找 ZIP 中的 .mlpackage，包含 ZIP 根目录本身。
    private func findMLPackage(in directory: URL, modelID: String) throws -> URL? {
        let fileManager = FileManager.default
        var packages: [URL] = []
        if isDirectory(directory), directory.pathExtension.lowercased() == "mlpackage" {
            packages.append(directory)
        }

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                if fileURL.pathExtension.lowercased() == "mlpackage", isDirectory(fileURL) {
                    packages.append(fileURL)
                    enumerator.skipDescendants()
                }
            }
        }

        let normalizedID = normalizedName(modelID)
        return packages.first {
            normalizedName($0.lastPathComponent).contains(normalizedID)
        } ?? packages.first
    }

    /// 查找预编译 Core ML 模型。
    /// 支持标准的 *.mlmodelc 目录，也支持 ZIP 直接打包其内部文件的情况。
    private func findCompiledModel(in directory: URL, modelID: String) -> URL? {
        let fileManager = FileManager.default
        var candidates: [URL] = []

        if isCompiledModelBundle(directory) {
            candidates.append(directory)
        }

        if let enumerator = fileManager.enumerator(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) {
            for case let fileURL as URL in enumerator {
                guard isDirectory(fileURL) else { continue }
                if fileURL.pathExtension.lowercased() == "mlmodelc" ||
                    isCompiledModelBundle(fileURL) {
                    candidates.append(fileURL)
                    enumerator.skipDescendants()
                }
            }
        }

        // 去重，避免根目录和遍历结果重复。
        var seen = Set<String>()
        candidates = candidates.filter { seen.insert($0.standardizedFileURL.path).inserted }

        let normalizedID = normalizedName(modelID)
        if let match = candidates.first(where: {
            normalizedName($0.lastPathComponent).contains(normalizedID)
        }) {
            return match
        }
        // ZIP 只包含一个模型时允许使用唯一候选；多个候选则拒绝猜测。
        return candidates.count == 1 ? candidates.first : nil
    }

    /// Core ML 编译目录的稳定特征文件。model.mil 是 ML Program 编译产物的主要标记。
    private func isCompiledModelBundle(_ url: URL) -> Bool {
        guard isDirectory(url) else { return false }
        let fileManager = FileManager.default
        let mil = url.appendingPathComponent("model.mil")
        let espresso = url.appendingPathComponent("model.espresso.net")
        let coreMLData = url.appendingPathComponent("coremldata.bin")
        return fileManager.fileExists(atPath: mil.path) ||
            fileManager.fileExists(atPath: espresso.path) ||
            fileManager.fileExists(atPath: coreMLData.path)
    }

    private func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    private func normalizedName(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// 安装失败时记录有限的解压目录结构，便于定位 Release ZIP 的实际布局。
    private func extractedContentsSummary(in directory: URL) -> String {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return "(无法读取解压目录)"
        }
        let names = urls.prefix(20).map { url -> String in
            let isDir = (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            return isDir ? "\(url.lastPathComponent)/" : url.lastPathComponent
        }
        return names.isEmpty ? "(目录为空)" : names.joined(separator: ", ")
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
            return "未找到 .mlmodelc 或 .mlpackage 目录"
        case .compileFailed(let detail):
            return "模型编译失败：\(detail)"
        case .moveFailed(let detail):
            return "文件移动失败：\(detail)"
        case .sinSRSubmodelNotFound:
            return "未找到 SinSR 子模型（Encoder/Decoder/Denoiser）"
        }
    }
}