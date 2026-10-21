// SuperResApp/Features/ModelManager/ModelManagerView.swift
// 模型管理页面：分组列表、下载/删除、存储用量

import SwiftUI

/// 模型管理页面
struct ModelManagerView: View {
    @StateObject private var viewModel = ModelManagerViewModel()

    var body: some View {
        NavigationStack {
            Group {
                if viewModel.isLoading {
                    loadingView
                } else {
                    modelList
                }
            }
            .navigationTitle("模型管理")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(action: {
                        Task { await viewModel.cleanupCache() }
                    }) {
                        Image(systemName: "trash")
                    }
                    .accessibilityLabel("清理缓存")
                }
            }
            .task {
                await viewModel.loadModels()
            }
            .alert("删除模型", isPresented: $viewModel.showDeleteConfirmation) {
                Button("取消", role: .cancel) {}
                Button("删除", role: .destructive) {
                    Task { await viewModel.confirmDelete() }
                }
            } message: {
                if let model = viewModel.modelToDelete {
                    Text("删除后需重新下载（约 \(model.formattedSize)）。")
                }
            }
            .alert("蜂窝网络下载", isPresented: $viewModel.showCellularConfirmation) {
                Button("取消", role: .cancel) {}
                Button("使用蜂窝下载") {
                    Task { await viewModel.confirmCellularDownload() }
                }
            } message: {
                if let model = viewModel.modelToDownload {
                    Text("\(model.name) 约 \(model.formattedSize)，建议在 Wi-Fi 下下载。")
                }
            }
        }
    }

    // MARK: - 模型列表

    private var modelList: some View {
        List {
            // 内置模型
            Section {
                ForEach(viewModel.builtinModels) { model in
                    ModelCardView(
                        model: model,
                        onDownload: {},
                        onPause: {},
                        onResume: {},
                        onDelete: {},
                        onRetry: {}
                    )
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets(top: 4, leading: DesignTokens.pageMargin, bottom: 4, trailing: DesignTokens.pageMargin))
                }
            } header: {
                Text("内置模型")
                    .font(AppFont.caption())
                    .foregroundColor(AppTheme.secondaryText)
            }

            // 可下载模型
            if !viewModel.downloadableModels.isEmpty {
                Section {
                    ForEach(viewModel.downloadableModels) { model in
                        ModelCardView(
                            model: model,
                            onDownload: { Task { await viewModel.downloadModel(model) } },
                            onPause: { Task { await viewModel.pauseDownload(model) } },
                            onResume: { Task { await viewModel.resumeDownload(model) } },
                            onDelete: { viewModel.requestDelete(model) },
                            onRetry: { Task { await viewModel.downloadModel(model) } }
                        )
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: DesignTokens.pageMargin, bottom: 4, trailing: DesignTokens.pageMargin))
                    }
                } header: {
                    Text("可下载模型")
                        .font(AppFont.caption())
                        .foregroundColor(AppTheme.secondaryText)
                }
            }

            // 存储用量
            Section {
                StorageUsageFooterView(
                    usedBytes: viewModel.storageUsed,
                    freeBytes: viewModel.storageFree
                )
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }
        }
        .listStyle(.plain)
        .background(AppTheme.groupedBackground)
        .scrollContentBackground(.hidden)
    }

    // MARK: - 加载中

    private var loadingView: some View {
        VStack(spacing: DesignTokens.spacingMD) {
            ProgressView()
                .scaleEffect(1.2)
            Text("加载模型清单…")
                .font(AppFont.body())
                .foregroundColor(AppTheme.secondaryText)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
