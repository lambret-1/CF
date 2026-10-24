// SuperResApp/Features/video/VideoSuperResView.swift

import SwiftUI
import PhotosUI
import AVKit

// MARK: - 通用按钮样式
private struct FilledButtonStyle: ButtonStyle {
    var color: Color
    var foreground: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .foregroundColor(foreground)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(
                color.opacity(configuration.isPressed ? 0.75 : 1),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
    }
}

struct VideoSuperResView: View {

    // ❗️关键修复：使用单例 + @ObservedObject。
    // View 销毁重建时拿到的仍是同一个 ViewModel，处理任务永不被打断。
    @ObservedObject private var viewModel = VideoSuperResViewModel.shared

    @State private var pickerItem: PhotosPickerItem?
    @State private var player: AVPlayer?
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            previewArea
            errorBanner
            Spacer(minLength: 0)
            
            // ⭐️ 将模型选择和分辨率选择统一放入一个 VStack 中
            VStack(spacing: 10) {
                modelMenu
                downscaleMenu
            }
            .padding(.horizontal)
            
            actionArea
        }
        .navigationTitle("视频超分")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { toolbarContent }
        .alert("提示", isPresented: alertBinding) {
            Button("好的", role: .cancel) { alertMessage = nil }
        } message: {
            Text(alertMessage ?? "")
        }
        // 进入页面：根据 ViewModel 当前状态恢复播放器（切 Tab 回来 / 返回时会触发）
        .onAppear { restorePlayer() }
        // ❗️关键修复：离开页面只暂停播放器，绝不动 ViewModel 的处理任务
        .onDisappear {
            player?.pause()
            player = nil
        }
        // 选视频后清空 pickerItem，允许重复选择同一视频
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await viewModel.handleVideoSelection(newItem)
                pickerItem = nil
            }
        }
        // 处理完成时（View 在前台）立即切换播放器
        .onChange(of: viewModel.resultVideoURL) { _, url in
            guard let url else { return }
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        }
        // 换原视频时刷新播放器
        .onChange(of: viewModel.originalVideoURL) { _, url in
            guard viewModel.state != .completed else { return }
            player?.pause()
            player = url.map { AVPlayer(url: $0) }
        }
    }

    // MARK: - 恢复播放器
    private func restorePlayer() {
        // 优先展示处理结果
        if viewModel.state == .completed, let url = viewModel.resultVideoURL {
            player = AVPlayer(url: url)
            player?.play()
            return
        }
        // 其次展示原视频
        if let url = viewModel.originalVideoURL {
            player = AVPlayer(url: url)
        }
    }

    // MARK: - Alert 绑定
    private var alertBinding: Binding<Bool> {
        Binding(
            get: { alertMessage != nil },
            set: { if !$0 { alertMessage = nil } }
        )
    }

    // MARK: - 预览区
    private var previewArea: some View {
        ZStack {
            Color.black.opacity(0.9)

            if let player {
                VideoPlayer(player: player)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "video.badge.plus")
                        .font(.system(size: 50))
                        .foregroundColor(.gray)
                    Text("请选择视频")
                        .foregroundColor(.gray)
                }
            }

            if viewModel.state == .processing {
                processingOverlay
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 220, idealHeight: 340, maxHeight: 380)
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .padding(.horizontal)
    }

    private var processingOverlay: some View {
        ZStack {
            Color.black.opacity(0.6)
            VStack(spacing: 16) {
                ProgressView(value: viewModel.progress)
                    .progressViewStyle(.linear)
                    .tint(.blue)
                    .frame(width: 200)

                Text("正在超分处理中 \(Int(viewModel.progress * 100))%")
                    .font(.subheadline)
                    .bold()
                    .foregroundColor(.white)
            }
        }
        .transition(.opacity)
    }

    // MARK: - 错误条
    @ViewBuilder
    private var errorBanner: some View {
        if case .failed(let message) = viewModel.state {
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.caption)
                .foregroundColor(.red)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal)
        }
    }

    // MARK: - 模型菜单
    private var modelMenu: some View {
        Menu {
            Picker("模型", selection: $viewModel.selectedModelID) {
                ForEach(SuperResModel.all) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "cpu")
                    .foregroundColor(.blue)
                
                Text("当前模型：\(SuperResModel.displayName(for: viewModel.selectedModelID))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .disabled(!viewModel.state.canEditModel)
    }

    // MARK: - ⭐️ 新增：降采样分辨率菜单
    private var downscaleMenu: some View {
        Menu {
            Picker("降采样分辨率", selection: $viewModel.selectedDownscaleOption) {
                ForEach(DownscaleOption.allCases) { option in
                    Text(option.rawValue).tag(option)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.down.right.and.arrow.up.left")
                    .foregroundColor(.orange)
                
                Text("输入采样分辨率：\(viewModel.selectedDownscaleOption.rawValue)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Spacer()

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .disabled(!viewModel.state.canEditModel)
    }

    // MARK: - 操作区
    @ViewBuilder
    private var actionArea: some View {
        VStack(spacing: 12) {
            switch viewModel.state {
            case .empty:
                photosPickerButton

            case .loading:
                loadingIndicator("正在加载视频…")

            case .videoSelected:
                Button("开始超分") {
                    Task { await viewModel.startProcessing() }
                }
                .buttonStyle(FilledButtonStyle(color: .blue))

            case .processing:
                // ❗️这是唯一允许打断任务的按钮
                Button("取消处理", role: .destructive) {
                    viewModel.cancelProcessing()
                }
                .buttonStyle(FilledButtonStyle(color: .red.opacity(0.1), foreground: .red))

            case .saving:
                loadingIndicator("正在保存到相册…")

            case .completed:
                Button("保存到相册") { save() }
                    .buttonStyle(FilledButtonStyle(color: .green))

            case .failed:
                if viewModel.originalVideoURL != nil {
                    Button("重试") {
                        Task { await viewModel.startProcessing() }
                    }
                    .buttonStyle(FilledButtonStyle(color: .blue))
                }
                photosPickerButton
            }
        }
        .padding(.horizontal)
        .padding(.bottom, 20)
    }

    private var photosPickerButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .videos) {
            Text("从相册选择视频")
                .font(.headline)
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(
                    Color.blue,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
        }
    }

    private func loadingIndicator(_ text: String) -> some View {
        HStack(spacing: 8) {
            ProgressView()
            Text(text)
                .font(.subheadline)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 14)
    }

    private func save() {
        Task {
            let ok = await viewModel.saveToAlbum()
            alertMessage = ok
                ? "视频已保存到相册"
                : "保存失败，请检查相册权限后重试"
        }
    }

    // MARK: - 工具栏
    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.state != .empty {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("重选") {
                    player?.pause()
                    player = nil
                    pickerItem = nil
                    viewModel.reset()   // busy 时内部 guard 直接拒绝
                }
                .disabled(viewModel.state.isBusy)
            }
        }
    }
}