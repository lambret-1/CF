import SwiftUI
import PhotosUI
import AVKit

struct VideoSuperResView: View {
    @StateObject private var viewModel = VideoSuperResViewModel()
    @State private var pickerItem: PhotosPickerItem?
    @State private var player: AVPlayer?
    
    // 弹出保存成功提示
    @State private var showSaveSuccessAlert = false
    
    // ⭐️ 支持的视频超分模型列表（只能放轻量模型，否则跑视频必闪退）
    private let supportedModels = [
        ("realesrgan-x4v3", "Real-ESRGAN x4v3 (轻量 4x)")
        // ("piper-sr-2x", "PiperSR 2x (极速 2x)") // 如果要用，需要去 ViewModel 里把 scaleFactor 改成 2
    ]
    
    var body: some View {
        VStack(spacing: 20) {
            
            // 1. 视频预览区
            ZStack {
                Color.black.opacity(0.9)
                
                if let player = player {
                    VideoPlayer(player: player)
                        .ignoresSafeArea(edges: .horizontal)
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "video.badge.plus")
                            .font(.system(size: 50))
                            .foregroundColor(.gray)
                        Text("请选择视频")
                            .foregroundColor(.gray)
                    }
                }
                
                // 处理中的遮罩层
                if viewModel.state == .processing {
                    Color.black.opacity(0.6)
                    VStack(spacing: 16) {
                        ProgressView(value: viewModel.progress)
                            .progressViewStyle(.linear)
                            .tint(.blue)
                            .frame(width: 200)
                        
                        Text("正在超分处理中 \(Int(viewModel.progress * 100))%")
                            .font(.subheadline)
                            .foregroundColor(.white)
                            .bold()
                    }
                }
            }
            .frame(height: 350)
            .cornerRadius(12)
            .padding(.horizontal)
            
            // 2. 错误提示
            if case .failed(let msg) = viewModel.state {
                Text(msg)
                    .foregroundColor(.red)
                    .font(.caption)
                    .padding(.horizontal)
            }
            
            Spacer()
            
            // ⭐️ 3. 模型切换菜单
            if viewModel.state != .processing {
                Menu {
                    ForEach(supportedModels, id: \.0) { model in
                        Button {
                            viewModel.selectedModelID = model.0
                        } label: {
                            HStack {
                                Text(model.1)
                                if viewModel.selectedModelID == model.0 {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                } label: {
                    HStack {
                        Text("当前模型：\(supportedModels.first(where: { $0.0 == viewModel.selectedModelID })?.1 ?? "未知")")
                            .font(.subheadline)
                            .fontWeight(.medium)
                            .foregroundColor(.primary)
                        
                        Image(systemName: "chevron.up.chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .background(Color(uiColor: .secondarySystemBackground))
                    .cornerRadius(10)
                }
                .disabled(viewModel.state == .completed) // 已经处理完时不建议切换
            }
            
            // 4. 底部操作按钮
            VStack(spacing: 12) {
                
                // 选择视频
                if viewModel.state == .empty || viewModel.originalVideoURL == nil {
                    PhotosPicker(selection: $pickerItem, matching: .videos) {
                        Text("从相册选择视频")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
                
                // 开始处理
                if viewModel.state == .videoSelected {
                    Button {
                        Task { await viewModel.startProcessing() }
                    } label: {
                        Text("开始超分")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.blue)
                            .cornerRadius(10)
                    }
                }
                
                // 处理中取消
                if viewModel.state == .processing {
                    Button(role: .destructive) {
                        viewModel.cancelProcessing()
                    } label: {
                        Text("取消处理")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.red.opacity(0.1))
                            .foregroundColor(.red)
                            .cornerRadius(10)
                    }
                }
                
                // 处理完成后的保存
                if viewModel.state == .completed {
                    Button {
                        Task {
                            await viewModel.saveToAlbum()
                            showSaveSuccessAlert = true
                        }
                    } label: {
                        Text("保存到相册")
                            .font(.headline)
                            .foregroundColor(.white)
                            .frame(maxWidth: .infinity)
                            .padding()
                            .background(Color.green)
                            .cornerRadius(10)
                    }
                }
            }
            .padding(.horizontal)
            .padding(.bottom, 20)
        }
        .navigationTitle("视频超分")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if viewModel.state != .empty {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("重选") {
                        player?.pause()
                        player = nil
                        viewModel.reset()
                    }
                }
            }
        }
        .alert("提示", isPresented: $showSaveSuccessAlert) {
            Button("好的", role: .cancel) { }
        } message: {
            Text("视频已保存到相册")
        }
        // 监听选择相册视频
        .onChange(of: pickerItem) { _, newItem in
            guard let newItem else { return }
            Task { await viewModel.handleVideoSelection(newItem) }
        }
        // 监听状态变化，刷新播放器
        .onChange(of: viewModel.state) { _, newState in
            if newState == .videoSelected, let url = viewModel.originalVideoURL {
                player?.pause()
                player = AVPlayer(url: url)
            } else if newState == .completed, let url = viewModel.resultVideoURL {
                player?.pause()
                player = AVPlayer(url: url)
                player?.play()
            }
        }
    }
}