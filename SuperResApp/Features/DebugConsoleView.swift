// SuperResApp/Services/DebugConsoleView.swift

import SwiftUI
import UIKit

struct DebugConsoleView: View {

    // 保留既有定义，不改 AppLogger / LogItem
    @ObservedObject var logger = AppLogger.shared

    // MARK: - 过滤条件

    @State private var selectedLevel: String = "全部"   // 全部 / INFO / ERROR
    @State private var searchText: String = ""

    // MARK: - 派生数据（缓存，避免每次 body 重算）

    @State private var displayItems: [LogItem] = []
    @State private var errorCount: Int = 0
    @State private var totalCount: Int = 0

    // MARK: - 交互状态

    @State private var autoScroll: Bool = true
    @State private var showClearConfirm: Bool = false
    @State private var showExportSheet: Bool = false
    @State private var exportURL: URL?
    @State private var showExportError: Bool = false
    @State private var exportErrorMessage: String = ""
    @State private var scrollToBottomToken: Int = 0
    @State private var searchDebounceTask: Task<Void, Never>?

    private let levels = ["全部", "INFO", "ERROR"]

    // MARK: - 视图主体

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchAndStatsBar
                filterSelector
                logContentArea
                bottomBar
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        autoScroll.toggle()
                        if autoScroll { scrollToBottomToken += 1 }
                    } label: {
                        Image(systemName: autoScroll ? "arrow.down.circle.fill" : "arrow.down.circle")
                            .foregroundColor(autoScroll ? .blue : .gray)
                    }
                    .accessibilityLabel(autoScroll ? "关闭自动滚动" : "开启自动滚动")
                }
            }
            .onAppear {
                rebuild()
                scrollToBottomToken += 1   // 首次进入滚到最新
            }
            .onDisappear {
                searchDebounceTask?.cancel()
                cleanupExportFile()
            }
            // 监听日志条数：追加时滚动，清空时只重建
            .onChangeCompat(of: logger.logs.count) { newCount in
                let isAppend = newCount > totalCount
                rebuild()
                if isAppend { scrollToBottomToken += 1 }
            }
            // 搜索防抖
            .onChangeCompat(of: searchText) { _ in
                scheduleSearchRebuild()
            }
            .alert("确认清空", isPresented: $showClearConfirm) {
                Button("取消", role: .cancel) { }
                Button("清空", role: .destructive) {
                    logger.clear()          // 保留既有方法
                }
            } message: {
                Text("确定要清空所有运行日志吗？此操作不可恢复。")
            }
            .alert("导出失败", isPresented: $showExportError) {
                Button("好", role: .cancel) { }
            } message: {
                Text(exportErrorMessage)
            }
            .sheet(isPresented: $showExportSheet, onDismiss: cleanupExportFile) {
                if let url = exportURL {
                    DebugActivityViewController(activityItems: [url])
                }
            }
        }
    }

    // MARK: - 搜索 + 统计合并栏

    private var searchAndStatsBar: some View {
        HStack(spacing: 10) {
            HStack {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundColor(.gray)
                TextField("搜索消息或时间", text: $searchText)
                    .font(.system(size: 13))
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                if !searchText.isEmpty {
                    Button {
                        searchText = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(.gray)
                    }
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Color(.systemGray6))
            .cornerRadius(6)

            Spacer()

            HStack(spacing: 8) {
                statItemCompact(label: "条", value: "\(displayItems.count)", color: .primary)
                statItemCompact(label: "错", value: "\(errorCount)", color: .red)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color(.systemBackground))
    }

    private func statItemCompact(label: String, value: String, color: Color) -> some View {
        HStack(spacing: 2) {
            Text(value)
                .font(.system(size: 12, weight: .bold))
                .foregroundColor(color)
            Text(label)
                .font(.system(size: 10))
                .foregroundColor(.secondary)
        }
    }

    // MARK: - 级别选择栏

    private var filterSelector: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(levels, id: \.self) { level in
                    Button {
                        guard selectedLevel != level else { return }
                        selectedLevel = level
                        rebuild()
                    } label: {
                        if level == "全部" {
                            Image(systemName: selectedLevel == "全部"
                                  ? "line.3.horizontal.decrease.circle.fill"
                                  : "line.3.horizontal.decrease.circle")
                                .font(.system(size: 12))
                                .foregroundColor(selectedLevel == "全部" ? .blue : .gray)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 4)
                        } else {
                            Text(level)
                                .font(.system(size: 11))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(selectedLevel == level
                                            ? levelColor(level).opacity(0.15)
                                            : Color.gray.opacity(0.1))
                                .foregroundColor(selectedLevel == level ? levelColor(level) : .primary)
                                .cornerRadius(4)
                        }
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
        }
        .background(Color(.systemGray6))
    }

    private func levelColor(_ level: String) -> Color {
        switch level {
        case "INFO":  return .blue
        case "ERROR": return .red
        default:      return .primary
        }
    }

    // MARK: - 日志内容区域

    private var logContentArea: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if displayItems.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "doc.text")
                            .font(.system(size: 40))
                            .foregroundColor(.gray)
                        Text("暂无匹配的日志记录")
                            .font(.system(size: 15))
                            .foregroundColor(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 60)
                } else {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(displayItems) { item in
                            DebugLogRow(item: item)
                                .id(item.id)     // LogItem.id 稳定，不重建整表
                        }
                    }
                    .padding(12)

                    Color.clear.frame(height: 1).id("bottom")
                }
            }
            .onChangeCompat(of: scrollToBottomToken) { _ in
                guard autoScroll else { return }
                DispatchQueue.main.async {
                    withAnimation {
                        proxy.scrollTo("bottom", anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(.systemBackground))
    }

    // MARK: - 底部操作栏

    private var bottomBar: some View {
        HStack(spacing: 10) {
            Button {
                rebuild()
                scrollToBottomToken += 1
            } label: {
                actionLabel(icon: "arrow.clockwise", title: "刷新", color: .blue)
            }

            Button {
                copyFilteredToClipboard()
            } label: {
                actionLabel(icon: "doc.on.doc", title: "复制", color: .green)
            }
            .disabled(displayItems.isEmpty)

            Button {
                prepareExport()
            } label: {
                actionLabel(icon: "square.and.arrow.up", title: "导出", color: .orange)
            }
            .disabled(displayItems.isEmpty)

            Button {
                showClearConfirm = true
            } label: {
                actionLabel(icon: "trash", title: "清空", color: .red)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.systemGray6))
    }

    private func actionLabel(icon: String, title: String, color: Color) -> some View {
        HStack {
            Image(systemName: icon)
            Text(title)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
        .background(color.opacity(0.1))
        .foregroundColor(color)
        .cornerRadius(8)
    }

    // MARK: - 数据重建

    /// 一次遍历同时产出「过滤结果」和「错误计数」，避免 body 里重算
    private func rebuild() {
        let all = logger.logs
        totalCount = all.count

        var filtered: [LogItem] = []
        var errs = 0
        filtered.reserveCapacity(all.count)

        let level = selectedLevel
        let query = searchText

        for item in all {
            if level == "INFO", item.isError { continue }
            if level == "ERROR", !item.isError { continue }

            if !query.isEmpty {
                let timeText = item.time.formatted(date: .omitted, time: .standard)
                if !item.message.localizedCaseInsensitiveContains(query),
                   !timeText.localizedCaseInsensitiveContains(query) {
                    continue
                }
            }

            filtered.append(item)
            if item.isError { errs += 1 }
        }

        displayItems = filtered
        errorCount = errs
    }

    private func scheduleSearchRebuild() {
        searchDebounceTask?.cancel()
        searchDebounceTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s 防抖
            guard !Task.isCancelled else { return }
            rebuild()
        }
    }

    // MARK: - 复制 / 导出

    private func copyFilteredToClipboard() {
        let text = displayItems.map { "\(formattedTime($0.time)) \($0.message)" }
                              .joined(separator: "\n")
        UIPasteboard.general.string = text
    }

    private func prepareExport() {
        let text = displayItems.map { "\(formattedTime($0.time)) \($0.message)" }
                              .joined(separator: "\n")
        guard !text.isEmpty else {
            exportErrorMessage = "当前没有可导出的日志内容。"
            showExportError = true
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let df = DateFormatter()
        df.dateFormat = "yyyyMMdd_HHmmss"
        let fileName = "console_logs_\(df.string(from: Date())).txt"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try text.write(to: fileURL, atomically: true, encoding: .utf8)
            exportURL = fileURL
            showExportSheet = true
        } catch {
            exportErrorMessage = error.localizedDescription
            showExportError = true
        }
    }

    private func cleanupExportFile() {
        guard let url = exportURL else { return }
        try? FileManager.default.removeItem(at: url)
        exportURL = nil
    }

    private func formattedTime(_ date: Date) -> String {
        date.formatted(date: .abbreviated, time: .standard)
    }
}

// MARK: - 日志行视图

private struct DebugLogRow: View {
    let item: LogItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.time.formatted(date: .omitted, time: .standard))
                .font(.system(size: 10, design: .monospaced))
                .foregroundColor(.gray)
            Text(item.message)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(item.isError ? .red : .primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 1)
    }
}

// MARK: - 分享封装（改名，避免与项目里已有的 ActivityViewController 冲突）

private struct DebugActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}

// MARK: - onChange 兼容层（private 扩展，文件作用域，不会与其他文件冲突）

private extension View {
    @ViewBuilder
    func onChangeCompat<V: Equatable>(
        of value: V,
        perform action: @escaping (V) -> Void
    ) -> some View {
        if #available(iOS 17.0, *) {
            self.onChange(of: value) { _, newValue in action(newValue) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}