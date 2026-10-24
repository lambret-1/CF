import SwiftUI

struct PhotoHomeView: View {
    var body: some View {
        NavigationStack {
            List {
                Section {
                    // 入口 1：照片超分
                    NavigationLink(destination: PhotoSuperResView()) {
                        HStack(spacing: 16) {
                            Image(systemName: "wand.and.stars")
                                .font(.system(size: 24))
                                .foregroundColor(.blue)
                                .frame(width: 40, height: 40)
                                .background(Color.blue.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("照片超分")
                                    .font(.headline)
                                Text("使用 AI 模型放大并增强照片画质")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                    
                    // 入口 2：真实色彩还原
                    NavigationLink(destination: PhotoRestoreView()) {
                        HStack(spacing: 16) {
                            Image(systemName: "paintpalette.fill")
                                .font(.system(size: 24))
                                .foregroundColor(.green)
                                .frame(width: 40, height: 40)
                                .background(Color.green.opacity(0.1))
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("真实色彩还原")
                                    .font(.headline)
                                Text("智能白平衡，修复偏色与异常色温")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                        }
                        .padding(.vertical, 8)
                    }
                } header: {
                    Text("照片工具")
                }
            }
            .navigationTitle("照片")
        }
    }
}