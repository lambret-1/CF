import SwiftUI

// 历史记录模型
struct RecentRecord: Identifiable {
    let id = UUID()
    let coverColor: Color // 模拟缩略图背景
    let tag: String       // 右上角标签，如 "AI补帧 (2x)" 或 "视频超分"
    let duration: String  // 左下角时长
    let fileName: String  // 文件名
    let resolution: String // 分辨率
    let fps: String       // 帧率
    let fileSize: String  // 大小
    let date: String      // 时间
}

struct HomeView: View {
    // 模拟数据
    let recentRecords: [RecentRecord] = [
        RecentRecord(coverColor: .blue.opacity(0.6), tag: "视频超分", duration: "0:05", fileName: "output_SR_94209B4...", resolution: "1520x2704", fps: "30fps", fileSize: "12.3 MB", date: "今天 03:15"),
        RecentRecord(coverColor: .black.opacity(0.8), tag: "AI补帧 (2x)", duration: "0:15", fileName: "output_FI_C620A0...", resolution: "720x1280", fps: "60fps", fileSize: "8.9 MB", date: "昨天 02:27")
    ]
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    
                    // 1. 功能大入口 (AI 补帧 & 视频超分)
                    HStack(spacing: 16) {
                        // 左侧：AI 补帧
                        NavigationLink(destination: FrameInterpolationView()) {
                            FeatureCard(icon: "slowmo", title: "AI 补帧", color: .purple)
                        }
                        
                        // 右侧：视频超分 (你刚才创建的页面)
                        NavigationLink(destination: VideoSuperResView()) {
                            FeatureCard(icon: "film.stack", title: "视频超分", color: .blue)
                        }
                    }
                    .padding(.horizontal)
                    
                    // 2. 最近记录标题栏
                    HStack {
                        Text("最近记录")
                            .font(.title3)
                            .fontWeight(.bold)
                        
                        Spacer()
                        
                        Button(action: {
                            // 跳转到全部记录页面
                            print("点击了全部")
                        }) {
                            HStack(spacing: 4) {
                                Text("全部")
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .bold))
                            }
                            .foregroundColor(.blue)
                        }
                    }
                    .padding(.horizontal)
                    
                    // 3. 最近记录卡片列表 (两列网格)
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)], spacing: 20) {
                        ForEach(recentRecords) { record in
                            RecentRecordCard(record: record)
                        }
                    }
                    .padding(.horizontal)
                }
                .padding(.top, 10)
            }
            .navigationTitle("AI 增强")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    HStack(spacing: 16) {
                        Button(action: {}) {
                            Image(systemName: "doc.text.magnifyingglass")
                                .foregroundColor(.primary)
                        }
                        Button(action: {}) {
                            Image(systemName: "gearshape")
                                .foregroundColor(.primary)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - 功能入口大卡片
struct FeatureCard: View {
    let icon: String
    let title: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 44))
                .foregroundColor(color)
            
            Text(title)
                .font(.headline)
                .foregroundColor(.primary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .background(Color(uiColor: .secondarySystemBackground))
        .cornerRadius(16)
    }
}

// MARK: - 最近记录卡片
struct RecentRecordCard: View {
    let record: RecentRecord
    
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 封面图区域
            ZStack(alignment: .topTrailing) {
                RoundedRectangle(cornerRadius: 12)
                    .fill(record.coverColor)
                    .frame(height: 100)
                
                // 右上角标签
                Text(record.tag)
                    .font(.system(size: 10, weight: .bold))
                    .foregroundColor(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 4)
                    .background(record.tag.contains("补帧") ? Color.purple : Color.blue) // 根据标签变颜色
                    .cornerRadius(4)
                    .padding(8)
                
                // 左下角时长
                VStack {
                    Spacer()
                    HStack {
                        Text(record.duration)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundColor(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.black.opacity(0.6))
                            .cornerRadius(4)
                        Spacer()
                    }
                }
                .padding(8)
            }
            
            // 文本信息区域
            VStack(alignment: .leading, spacing: 4) {
                Text(record.fileName)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                    .foregroundColor(.primary)
                
                Text("\(record.resolution) · \(record.fps) · \(record.fileSize)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                
                Text(record.date)
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
        }
    }
}

// MARK: - ⭐️ AI 补帧占位页面
// 因为你还没开发补帧的核心代码，这里先放一个占位图，防止点击报错。
struct FrameInterpolationView: View {
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "slowmo")
                .font(.system(size: 60))
                .foregroundColor(.purple)
            Text("AI 补帧功能开发中...")
                .font(.headline)
                .foregroundColor(.gray)
            Text("(需要引入 CoreML 的插帧模型，如 RIFE 或 FILM)")
                .font(.caption)
                .foregroundColor(.gray)
        }
        .navigationTitle("AI 补帧")
    }
}