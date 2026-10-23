// SuperResApp/Services/ModelDownloader.swift
// 模型下载器：后台 URLSession、断点续传、队列管理、SHA256 校验、仅 Wi-Fi 判断

import Foundation
import CryptoKit

/// 模型下载器，负责管理所有模型的下载任务
actor ModelDownloader: NSObject {
    /// 单例
    static let shared = ModelDownloader()

    // 共享容器 ID
    private let appGroupID = "group.com.superres.app"

    // MARK: - 回调类型

    typealias ProgressHandler = (String, Int64, Int64, Double) -> Void
    typealias CompletionHandler = (String, URL) -> Void
    typealias FailureHandler = (String, Error) -> Void

    // MARK: - 属性

    private var session: URLSession!
    private let manifestLoader = ModelManifestLoader.shared
    private let networkMonitor = NetworkMonitor.shared

    private var activeTask: URLSessionDownloadTask?
    private var activeModelID: String?
    private var queue: [DownloadQueueItem] = []
    private var taskModelMap: [Int: String] = [:]
    var progressHandler: ProgressHandler?
    var completionHandler: CompletionHandler?
    var failureHandler: FailureHandler?

    private let queueFileURL: URL
    private let tempDirectory: URL

    // MARK: - 初始化

    private override init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let supportDir = paths[0]
        queueFileURL = supportDir.appendingPathComponent("download_queue.json")
        
        // ⭐️ 如果支持 App Group，把临时目录放到共享容器里；否则退回私有临时目录
        if let containerURL = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: "group.com.superres.app") {
            tempDirectory = containerURL.appendingPathComponent("SuperResDownloads", isDirectory: true)
        } else {
            tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SuperResDownloads", isDirectory: true)
        }
        
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.superres.model-download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 24 // 24小时
        // ⭐️ 核心：告诉系统把文件下载到共享容器里
        config.sharedContainerIdentifier = "group.com.superres.app"
        
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        restoreQueue()
    }

    // MARK: - 队列持久化

    private func saveQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            NSLog("保存下载队列失败：\(error.localizedDescription)")
        }
    }

    private func restoreQueue() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let savedQueue = try? JSONDecoder().decode([DownloadQueueItem].self, from: data) else {
            return
        }
        queue = savedQueue
        if let first = queue.first, !first.isPaused {
            Task {
                await startNext()
            }
        }
    }

    // MARK: - 公共接口

    func download(modelID: String) async {
        if queue.contains(where: { $0.id == modelID }) || activeModelID == modelID {
            return
        }

        guard let item = await manifestLoader.manifestItem(for: modelID) else {
            await manifestLoader.markFailed(id: modelID, reason: "模型不存在")
            return
        }

        let canDownload = await networkMonitor.canDownload(wifiOnly: item.wifiOnly)
        if !canDownload {
            if item.wifiOnly {
                let isCellular = await networkMonitor.isCellular
                if isCellular {
                    await manifestLoader.markFailed(id: modelID, reason: "此模型仅支持 Wi-Fi 下载")
                } else {
                    await manifestLoader.markFailed(id: modelID, reason: "网络连接不可用")
                }
            } else {
                await manifestLoader.markFailed(id: modelID, reason: "网络连接不可用")
            }
            return
        }

        let queueItem = DownloadQueueItem(
            id: modelID,
            resumeData: nil,
            downloadedBytes: 0,
            queuedAt: Date(),
            isPaused: false
        )
        queue.append(queueItem)
        saveQueue()
        await manifestLoader.updateStatus(.queued, for: modelID)

        if activeTask == nil {
            await startNext()
        }
    }

    func pause(modelID: String) async {
        if activeModelID == modelID, let task = activeTask {
            task.cancel { [weak self] resumeData in
                Task { [weak self] in
                    await self?.handlePause(modelID: modelID, resumeData: resumeData)
                }
            }
        } else if let index = queue.firstIndex(where: { $0.id == modelID }) {
            queue[index].isPaused = true
            saveQueue()
            await manifestLoader.updateStatus(.paused, for: modelID)
        }
    }

    private func handlePause(modelID: String, resumeData: Data?) async {
        activeTask = nil
        activeModelID = nil
        if let index = queue.firstIndex(where: { $0.id == modelID }) {
            queue[index].isPaused = true
            queue[index].resumeData = resumeData
        } else {
            let item = DownloadQueueItem(
                id: modelID,
                resumeData: resumeData,
                downloadedBytes: 0,
                queuedAt: Date(),
                isPaused: true
            )
            queue.insert(item, at: 0)
        }
        saveQueue()
        await manifestLoader.updateStatus(.paused, for: modelID)
        await startNext()
    }

    func resume(modelID: String) async {
        if let index = queue.firstIndex(where: { $0.id == modelID }) {
            queue[index].isPaused = false
            saveQueue()
            await manifestLoader.updateStatus(.queued, for: modelID)
            if activeTask == nil {
                await startNext()
            }
        }
    }

    func cancel(modelID: String) async {
        if activeModelID == modelID {
            activeTask?.cancel()
            activeTask = nil
            activeModelID = nil
        }
        queue.removeAll { $0.id == modelID }
        saveQueue()
        await manifestLoader.updateStatus(.notDownloaded, for: modelID)
        await manifestLoader.updateProgress(0, downloadedBytes: 0, for: modelID)
        await startNext()
    }

    func queuedModels() -> [DownloadQueueItem] {
        queue
    }

    func currentDownloadingID() -> String? {
        activeModelID
    }

    // MARK: - 内部方法

    private func startNext() async {
        guard activeTask == nil else { return }

        guard let index = queue.firstIndex(where: { !$0.isPaused }) else { return }

        let item = queue[index]
        guard let manifest = await manifestLoader.manifestItem(for: item.id) else {
            await manifestLoader.markFailed(id: item.id, reason: "模型不存在")
            queue.remove(at: index)
            saveQueue()
            await startNext()
            return
        }

        let cleanUrlString = manifest.url.trimmingCharacters(in: .whitespacesAndNewlines)
        
        guard let url = URL(string: cleanUrlString) else {
            let errorMsg = "下载地址无效，解析失败: [\(cleanUrlString)]"
            await AppLogger.shared.log(errorMsg, isError: true)
            await manifestLoader.markFailed(id: item.id, reason: "下载地址无效")
            queue.remove(at: index)
            saveQueue()
            await startNext()
            return
        }

        activeModelID = item.id
        await manifestLoader.updateStatus(.downloading, for: item.id)

        let task: URLSessionDownloadTask
        if let resumeData = item.resumeData {
            task = session.downloadTask(withResumeData: resumeData)
        } else {
            task = session.downloadTask(with: url)
        }
        taskModelMap[task.taskIdentifier] = item.id
        task.resume()
        activeTask = task
    }

    private func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard !expected.isEmpty else { return true }
        do {
            let data = try Data(contentsOf: fileURL)
            let hash = sha256(data: data)
            return hash.lowercased() == expected.lowercased()
        } catch {
            return false
        }
    }

    private func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// ==========================================
// ⭐️ 请在这里换行，接着粘贴下面的第二段代码
// ==========================================
// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        let taskID = downloadTask.taskIdentifier
        let fileManager = FileManager.default
        
        // ⭐️ 核心修复：在共享容器内，直接将文件移过去，不需要用 Data(contentsOf:)
        let tempDir: URL
        if let containerURL = fileManager.containerURL(forSecurityApplicationGroupIdentifier: "group.com.superres.app") {
            tempDir = containerURL.appendingPathComponent("SuperResDownloads", isDirectory: true)
        } else {
            tempDir = fileManager.temporaryDirectory.appendingPathComponent("SuperResDownloads", isDirectory: true)
        }
        
        do {
            try fileManager.createDirectory(at: tempDir, withIntermediateDirectories: true)
            
            let tempFileName = UUID().uuidString + ".zip"
            let tempURL = tempDir.appendingPathComponent(tempFileName)
            
            if fileManager.fileExists(atPath: tempURL.path) {
                try fileManager.removeItem(at: tempURL)
            }
            
            // 因为是同一个 sharedContainer，moveItem 拥有最高权限，秒过
            try fileManager.moveItem(at: location, to: tempURL)
            
            Task {
                await self.handleDownloadFinished(taskID: taskID, tempURL: tempURL)
            }
        } catch {
            Task {
                await AppLogger.shared.log("保存下载文件失败: \(error.localizedDescription)", isError: true)
                await self.handleDownloadError(taskID: taskID, error: error)
            }
        }
    }

    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                                 totalBytesExpectedToWrite: Int64) {
        Task {
            await self.handleDownloadProgress(
                task: downloadTask,
                bytesWritten: bytesWritten,
                totalBytesWritten: totalBytesWritten,
                totalBytesExpected: totalBytesExpectedToWrite
            )
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        Task {
            await self.handleTaskCompletion(task: task, error: error)
        }
    }

    func handleDownloadFinished(taskID: Int, tempURL: URL) async {
        guard let modelID = taskModelMap[taskID] else {
            try? FileManager.default.removeItem(at: tempURL)
            return
        }
        taskModelMap.removeValue(forKey: taskID)

        let destination = tempDirectory.appendingPathComponent("\(modelID).zip")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: tempURL, to: destination)
        } catch {
            await manifestLoader.markFailed(id: modelID, reason: "文件移动失败：\(error.localizedDescription)")
            await failureHandler?(modelID, error)
            await finishDownload(modelID: modelID)
            return
        }

        if let manifest = await manifestLoader.manifestItem(for: modelID) {
            if !verifySHA256(fileURL: destination, expected: manifest.sha256) {
                try? FileManager.default.removeItem(at: destination)
                await manifestLoader.markFailed(id: modelID, reason: "SHA256 校验失败，文件可能已损坏")
                await failureHandler?(modelID, DownloadError.sha256Mismatch)
                await finishDownload(modelID: modelID)
                return
            }
        }

        let receivedBytes = (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int64) ?? 0

        activeTask = nil
        activeModelID = nil
        queue.removeAll { $0.id == modelID }
        saveQueue()

        await manifestLoader.updateProgress(1.0, downloadedBytes: receivedBytes, for: modelID)
        await completionHandler?(modelID, destination)
        await startNext()
    }

    func handleDownloadError(taskID: Int, error: Error) async {
        guard let modelID = taskModelMap[taskID] else { return }
        taskModelMap.removeValue(forKey: taskID)
        
        activeTask = nil
        activeModelID = nil
        
        await manifestLoader.markFailed(id: modelID, reason: "保存文件失败：\(error.localizedDescription)")
        await failureHandler?(modelID, error)
        await finishDownload(modelID: modelID)
    }

    func handleDownloadProgress(task: URLSessionDownloadTask, bytesWritten: Int64,
                                         totalBytesWritten: Int64, totalBytesExpected: Int64) async {
        guard let modelID = taskModelMap[task.taskIdentifier] else { return }
        let progress = totalBytesExpected > 0 ? Double(totalBytesWritten) / Double(totalBytesExpected) : 0
        await manifestLoader.updateProgress(progress, downloadedBytes: totalBytesWritten, for: modelID)
        await progressHandler?(modelID, totalBytesWritten, totalBytesExpected, progress)

        if let index = queue.firstIndex(where: { $0.id == modelID }) {
            queue[index].downloadedBytes = totalBytesWritten
        }
    }

    func handleTaskCompletion(task: URLSessionTask, error: Error?) async {
        guard let modelID = taskModelMap[task.taskIdentifier] else { return }

        if let error = error as NSError? {
            if error.code == NSURLErrorCancelled {
                taskModelMap.removeValue(forKey: task.taskIdentifier)
                return
            }

            let resumeData = (error.userInfo[NSURLSessionDownloadTaskResumeData] as? Data)
            taskModelMap.removeValue(forKey: task.taskIdentifier)

            activeTask = nil
            activeModelID = nil

            if let index = queue.firstIndex(where: { $0.id == modelID }) {
                queue[index].resumeData = resumeData
            }
            saveQueue()

            await manifestLoader.markFailed(id: modelID, reason: "下载失败：\(error.localizedDescription)")
            await failureHandler?(modelID, error)
            await startNext()
        }
    }

    private func finishDownload(modelID: String) async {
        activeTask = nil
        activeModelID = nil
        queue.removeAll { $0.id == modelID }
        saveQueue()
        await startNext()
    }
}

// MARK: - 下载错误

enum DownloadError: LocalizedError {
    case sha256Mismatch
    case invalidURL
    case networkUnavailable
    case wifiOnlyRestricted

    var errorDescription: String? {
        switch self {
        case .sha256Mismatch:
            return "SHA256 校验失败"
        case .invalidURL:
            return "下载地址无效"
        case .networkUnavailable:
            return "网络连接不可用"
        case .wifiOnlyRestricted:
            return "此模型仅支持 Wi-Fi 下载"
        }
    }
}