// SuperResApp/Services/DebugConsoleView.swift

import SwiftUI

struct DebugConsoleView: View {
    @ObservedObject var logger = AppLogger.shared
    
    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
                List(logger.logs) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.time.formatted(date: .omitted, time: .standard))
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundColor(.gray)
                        Text(item.message)
                            .font(.system(size: 12, design: .monospaced))
                            .foregroundColor(item.isError ? .red : .primary)
                    }
                    .id(item.id)
                }
                .listStyle(.plain)
                .onChange(of: logger.logs.count) { _, _ in
                    if let last = logger.logs.last {
                        withAnimation {
                            proxy.scrollTo(last.id, anchor: .bottom)
                        }
                    }
                }
            }
            .navigationTitle("运行日志")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button("清空") { logger.clear() }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button {
                        logger.copyToClipboard()
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                }
            }
        }
    }
}