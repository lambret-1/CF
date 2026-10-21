// SuperResApp/Services/ModelDownloader.swift
// 模型下载器：后台 URLSession、断点续传、队列管理、SHA256 校验、仅 Wi-Fi 判断

import Foundation
import CryptoKit

/// 模型下载器，负责管理所有模型的下载任务
actor ModelDownloader: NSObject {
    /// 单例
    static let shared = ModelDownloader()

    // MARK: - 回调类型

    /// 进度回调：(模型id, 已下载字节, 总字节, 进度0-1)
    typealias ProgressHandler = (String, Int64, Int64, Double) -> Void
    /// 完成回调：(模型id, 本地文件URL)
    typealias CompletionHandler = (String, URL) -> Void
    /// 失败回调：(模型id, 错误)
    typealias FailureHandler = (String, Error) -> Void

    // MARK: - 属性

    private var session: URLSession!
    private let manifestLoader = ModelManifestLoader.shared
    private let networkMonitor = NetworkMonitor.shared

    /// 当前下载中的任务
    private var activeTask: URLSessionDownloadTask?
    /// 当前下载的模型 id
    private var activeModelID: String?
    /// 下载队列
    private var queue: [DownloadQueueItem] = []
    /// 任务与模型 id 的映射
    private var taskModelMap: [Int: String] = [:]
    /// 下载进度回调
    var progressHandler: ProgressHandler?
    /// 下载完成回调
    var completionHandler: CompletionHandler?
    /// 下载失败回调
    var failureHandler: FailureHandler?

    /// 下载队列持久化文件路径
    private let queueFileURL: URL

    /// 临时下载目录
    private let tempDirectory: URL

    // MARK: - 初始化

    private override init() {
        let paths = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let supportDir = paths[0]
        queueFileURL = supportDir.appendingPathComponent("download_queue.json")
        tempDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("SuperResDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)

        super.init()

        let config = URLSessionConfiguration.background(withIdentifier: "com.superres.model-download")
        config.isDiscretionary = false
        config.sessionSendsLaunchEvents = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60 * 60 * 24 // 24小时
        session = URLSession(configuration: config, delegate: self, delegateQueue: nil)

        restoreQueue()
    }

    // MARK: - 队列持久化

    /// 保存下载队列到磁盘
    private func saveQueue() {
        do {
            let data = try JSONEncoder().encode(queue)
            try data.write(to: queueFileURL, options: .atomic)
        } catch {
            NSLog("保存下载队列失败：\(error.localizedDescription)")
        }
    }

    /// 从磁盘恢复下载队列
    private func restoreQueue() {
        guard let data = try? Data(contentsOf: queueFileURL),
              let savedQueue = try? JSONDecoder().decode([DownloadQueueItem].self, from: data) else {
            return
        }
        queue = savedQueue
        // 恢复后自动开始队列中的第一个任务
        if let first = queue.first, !first.isPaused {
            Task {
                await startNext()
            }
        }
    }

    // MARK: - 公共接口

    /// 开始下载模型
    /// - Parameter modelID: 模型 id
    func download(modelID: String) async {
        // 检查是否已在队列中
        if queue.contains(where: { $0.id == modelID }) || activeModelID == modelID {
            return
        }

        guard let item = await manifestLoader.manifestItem(for: modelID) else {
            await manifestLoader.markFailed(id: modelID, reason: "模型不存在")
            return
        }

        // 检查网络
        let canDownload = await networkMonitor.canDownload(wifiOnly: item.wifiOnly)
        if !canDownload {
            if item.wifiOnly && await networkMonitor.isCellular {
                await manifestLoader.markFailed(id: modelID, reason: "此模型仅支持 Wi-Fi 下载")
            } else {
                await manifestLoader.markFailed(id: modelID, reason: "网络连接不可用")
            }
            return
        }

        // 加入队列
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

        // 如果当前没有下载任务，立即开始
        if activeTask == nil {
            await startNext()
        }
    }

    /// 暂停下载
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

    /// 恢复下载
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

    /// 取消下载
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

    /// 获取下载队列
    func queuedModels() -> [DownloadQueueItem] {
        queue
    }

    /// 当前下载中的模型 id
    func currentDownloadingID() -> String? {
        activeModelID
    }

    // MARK: - 内部方法

    /// 开始队列中的下一个下载任务
    private func startNext() async {
        guard activeTask == nil else { return }

        // 找到第一个未暂停的任务
        guard let index = queue.firstIndex(where: { !$0.isPaused }) else { return }

        let item = queue[index]
        guard let manifest = await manifestLoader.manifestItem(for: item.id),
              let url = URL(string: manifest.url) else {
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

    /// 校验 SHA256
    private func verifySHA256(fileURL: URL, expected: String) -> Bool {
        guard !expected.isEmpty else { return true } // 留空表示不校验
        do {
            let data = try Data(contentsOf: fileURL)
            let hash = sha256(data: data)
            return hash.lowercased() == expected.lowercased()
        } catch {
            return false
        }
    }

    /// 计算 SHA256
    private func sha256(data: Data) -> String {
        let digest = SHA256.hash(data: data)
        return digest.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - URLSessionDownloadDelegate

extension ModelDownloader: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                                 didFinishDownloadingTo location: URL) {
        Task {
            await self.handleDownloadFinished(task: downloadTask, location: location)
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

    private func handleDownloadFinished(task: URLSessionDownloadTask, location: URL) async {
        guard let modelID = taskModelMap[task.taskIdentifier] else { return }
        taskModelMap.removeValue(forKey: task.taskIdentifier)

        // 移动到临时目录
        let destination = tempDirectory.appendingPathComponent("\(modelID).zip")
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.moveItem(at: location, to: destination)
        } catch {
            await manifestLoader.markFailed(id: modelID, reason: "文件保存失败：\(error.localizedDescription)")
            await failureHandler?(modelID, error)
            await finishDownload(modelID: modelID)
            return
        }

        // SHA256 校验
        if let manifest = await manifestLoader.manifestItem(for: modelID) {
            if !verifySHA256(fileURL: destination, expected: manifest.sha256) {
                try? FileManager.default.removeItem(at: destination)
                await manifestLoader.markFailed(id: modelID, reason: "SHA256 校验失败，文件可能已损坏")
                await failureHandler?(modelID, DownloadError.sha256Mismatch)
                await finishDownload(modelID: modelID)
                return
            }
        }

        activeTask = nil
        activeModelID = nil
        queue.removeAll { $0.id == modelID }
        saveQueue()

        await manifestLoader.updateProgress(1.0, downloadedBytes: task.countOfBytesReceived, for: modelID)
        await completionHandler?(modelID, destination)
        await startNext()
    }

    private func handleDownloadProgress(task: URLSessionDownloadTask, bytesWritten: Int64,
                                         totalBytesWritten: Int64, totalBytesExpected: Int64) async {
        guard let modelID = taskModelMap[task.taskIdentifier] else { return }
        let progress = totalBytesExpected > 0 ? Double(totalBytesWritten) / Double(totalBytesExpected) : 0
        await manifestLoader.updateProgress(progress, downloadedBytes: totalBytesWritten, for: modelID)
        await progressHandler?(modelID, totalBytesWritten, totalBytesExpected, progress)

        // 更新队列中的已下载字节
        if let index = queue.firstIndex(where: { $0.id == modelID }) {
            queue[index].downloadedBytes = totalBytesWritten
        }
    }

    private func handleTaskCompletion(task: URLSessionTask, error: Error?) async {
        guard let modelID = taskModelMap[task.taskIdentifier] else { return }

        if let error = error as NSError? {
            // 用户取消不算失败
            if error.code == NSURLErrorCancelled {
                taskModelMap.removeValue(forKey: task.taskIdentifier)
                return
            }

            // 尝试获取 resumeData 用于断点续传
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
