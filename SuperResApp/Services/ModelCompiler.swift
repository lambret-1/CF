func compile(modelID: String, zipURL: URL) async throws -> URL {
        await manifestLoader.updateStatus(.compiling, for: modelID)

        let fileManager = FileManager.default
        let paths = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        
        // ⭐️ 编译临时目录也放到 Application Support 下，彻底避开 tmp 权限问题
        let modelsDir = paths[0].appendingPathComponent("Models", isDirectory: true)
        let compileTempRoot = modelsDir.appendingPathComponent("CompileTemp", isDirectory: true)
        let tempDir = compileTempRoot.appendingPathComponent(modelID, isDirectory: true)

        try? fileManager.removeItem(at: tempDir)
        try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)

        defer {
            try? fileManager.removeItem(at: tempDir)
            try? fileManager.removeItem(at: zipURL)
        }

        do {
            try fileManager.unzipItem(at: zipURL, to: tempDir)
        } catch {
            await manifestLoader.markFailed(id: modelID, reason: "解压失败：\(error.localizedDescription)")
            throw CompileError.unzipFailed(error.localizedDescription)
        }

        guard let packageURL = try findMLPackage(in: tempDir, modelID: modelID) else {
            await manifestLoader.markFailed(id: modelID, reason: "未找到 .mlpackage 目录")
            throw CompileError.packageNotFound
        }

        let compiledURL: URL
        do {
            compiledURL = try await MLModel.compileModel(at: packageURL)
        } catch {
            await manifestLoader.markFailed(id: modelID, reason: "编译失败：\(error.localizedDescription)")
            throw CompileError.compileFailed(error.localizedDescription)
        }

        let destination = await manifestLoader.compiledModelURL(for: modelID)
        let destDir = destination.deletingLastPathComponent()
        
        try? fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

        if fileManager.fileExists(atPath: destination.path) {
            try? fileManager.removeItem(at: destination)
        }

        do {
            try fileManager.moveItem(at: compiledURL, to: destination)
        } catch {
            try fileManager.copyItem(at: compiledURL, to: destination)
        }

        await manifestLoader.updateStatus(.downloaded, for: modelID)
        return destination
    }