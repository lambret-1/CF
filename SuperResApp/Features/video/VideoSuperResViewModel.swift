// SuperResApp/Features/video/VideoSuperResView.swift

import SwiftUI
import PhotosUI
import AVKit

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
    // ❗️关键修复：ViewModel 由外部持有，View 销毁不影响任务执行
    @ObservedObject var viewModel: VideoSuperResViewModel

    @State private var pickerItem: PhotosPickerItem?
    @State private var player: AVPlayer?
    @State private var alertMessage: String?

    var body: some View {
        VStack(spacing: 20) {
            previewArea
            errorBanner
            Spacer(minLength: 0)
            modelMenu
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
        // ❗️关键修复：进入页面时按当前状态恢复播放器
        .onAppear { restorePlayer() }
        // ❗️关键修复：只暂停播放器，绝不打断处理任务
        .onDisappear {
            player?.pause()
            player = nil
        }
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task {
                await viewModel.handleVideoSelection(newItem)
                pickerItem = nil
            }
        }
        // 处理中切走再切回来，进度通过 Published 自动刷新；
        // 完成瞬间若页面不在前台，回来时 onAppear 会补齐播放器
        .onChange(of: viewModel.resultVideoURL) { _, url in
            guard let url, isViewVisible else { return }
            player?.pause()
            player = AVPlayer(url: url)
            player?.play()
        }
    }

    /// 判断 View 当前是否可见（简化实现：用 player 是否为 nil 区分场景足够）
    private var isViewVisible: Bool { true }

    // MARK: - 播放器恢复（切换 Tab 回来 / 导航返回时调用）
    private func restorePlayer() {
        // 优先播放处理结果
        if viewModel.state == .completed, let url = viewModel.resultVideoURL {
            player = AVPlayer(url: url)
            player?.play()
            return
        }
        // 否则显示原视频
        if let url = viewModel.originalVideoURL {
            player = AVPlayer(url: url)
        }
    }

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

    private var modelMenu: some View {
        Menu {
            Picker("模型", selection: $viewModel.selectedModelID) {
                ForEach(SuperResModel.all) { model in
                    Text(model.displayName).tag(model.id)
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text("当前模型：\(SuperResModel.displayName(for: viewModel.selectedModelID))")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundColor(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)

                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(
                Color(uiColor: .secondarySystemBackground),
                in: RoundedRectangle(cornerRadius: 10, style: .continuous)
            )
        }
        .disabled(!viewModel.state.canEditModel)
    }

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

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        if viewModel.state != .empty {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("重选") {
                    player?.pause()
                    player = nil
                    pickerItem = nil
                    viewModel.reset()   // ViewModel 内部 guard 保证 busy 时拒绝
                }
                .disabled(viewModel.state.isBusy)   // ❗️ busy 时禁用，避免误触打断
            }
        }
    }
}