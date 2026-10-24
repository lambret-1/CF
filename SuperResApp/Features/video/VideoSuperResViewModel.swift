// MARK: - 开始处理
    func startProcessing() async {
        guard let inputURL = originalVideoURL else { return }
        guard state == .videoSelected || state.isFailed else { return }

        state = .processing
        progress = 0.0

        // ❗️进入处理前申请后台执行时间（App 在后台时也能继续跑）
        beginBackgroundTaskIfNeeded()

        let gen = generation
        let outputURL = tempDirectory
            .appendingPathComponent("superres_\(Int(Date().timeIntervalSince1970)).mov")
        let newProcessor = VideoSuperResProcessor()
        self.processor = newProcessor

        // 获取当前 UI 选择的模型和缩放倍数
        let scale = currentScaleFactor
        let modelID = selectedModelID
        AppLogger.shared.log(
            "[视频控制] 准备超分引擎，模型: \(modelID)，倍数: \(scale)x",
            isError: false
        )

        do {
            // 1. 初始化降采样引擎
            AppLogger.shared.log("[视频控制] 正在初始化降采样...", isError: false)
            let downscaler = try VideoDownscaler(
                config: .init(targetShortSide: 272, alignment: 16),
                mtlDevice: MTLCreateSystemDefaultDevice()
            )
            
            // 2. 打开源视频，获取帧流
            let source = try await downscaler.open(inputURL)
            AppLogger.shared.log(
                "[视频控制] 降采样就绪，中间尺寸: \(Int(source.metadata.targetSize.width))x\(Int(source.metadata.targetSize.height))",
                isError: false
            )

            // 3. 动态计算最终输出尺寸（保持 16:9 且对齐偶数，防止播放器拉伸或 HEVC 报错）
            // 如果目标短边是 272，4x 后长边会变成 1088（非标准 1080p），这里强制修正。
            let targetOutputSize: CGSize?
            if scale == 4 {
                targetOutputSize = CGSize(width: 1920, height: 1080) // 4x 统一输出标准 1080p
            } else if scale == 2 {
                targetOutputSize = CGSize(width: 960, height: 540)   // 2x 统一输出标准 540p
            } else {
                targetOutputSize = nil // 其他倍数则交由 Processor 内部按 targetSize * scale 计算
            }

            // 4. 开始超分与编码
            try await newProcessor.processVideo(
                source: source,
                audioSourceURL: inputURL,       // 传入原始 URL 用于无损直通音频
                outputURL: outputURL,
                modelID: modelID,
                scaleFactor: scale,
                targetOutputSize: targetOutputSize,
                progressHandler: { [weak self] p in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == gen else { return }
                        let safe = p.isFinite ? min(max(p, 0), 1) : 0
                        self.progress = safe
                    }
                }
            )

            guard generation == gen else {
                try? FileManager.default.removeItem(at: outputURL)
                endBackgroundTaskIfNeeded()
                return
            }

            self.resultVideoURL = outputURL
            self.progress = 1.0
            self.state = .completed
            self.processor = nil
            endBackgroundTaskIfNeeded()
            AppLogger.shared.log("[视频控制] 视频处理完毕，准备预览。", isError: false)

        } catch is CancellationError {
            try? FileManager.default.removeItem(at: outputURL)
            if generation == gen {
                self.state = originalVideoURL != nil ? .videoSelected : .empty
                self.progress = 0.0
                self.processor = nil
            }
            endBackgroundTaskIfNeeded()
            AppLogger.shared.log("[视频控制] 任务被取消。", isError: false)

        } catch {
            try? FileManager.default.removeItem(at: outputURL)
            guard generation == gen else {
                endBackgroundTaskIfNeeded()
                return
            }
            self.state = .failed("视频处理失败: \(error.localizedDescription)")
            self.progress = 0.0
            self.processor = nil
            endBackgroundTaskIfNeeded()
            AppLogger.shared.log(
                "[视频控制] 任务异常中止: \(error.localizedDescription)",
                isError: true
            )
        }
    }