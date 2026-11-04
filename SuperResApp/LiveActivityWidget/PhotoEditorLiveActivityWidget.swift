import ActivityKit
import SwiftUI
import WidgetKit


@main
struct PhotoEditorLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhotoEditorActivityAttributes.self) { context in
            HStack(spacing: 12) {
                Image(systemName: "slider.horizontal.3")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CF 照片编辑").font(.system(size: 14, weight: .semibold))
                    Text("编辑中").font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                islandAction("取消", icon: "xmark", destination: "cancel", tint: .white.opacity(0.78))
                islandAction("完成", icon: "checkmark", destination: "complete", tint: .black)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "slider.horizontal.3").font(.system(size: 20, weight: .semibold)).foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.center) {
                    Text("CF 照片编辑")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        islandAction("取消", icon: "xmark", destination: "cancel", tint: .white.opacity(0.78))
                        islandAction("完成", icon: "checkmark", destination: "complete", tint: .black)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Link(destination: URL(string: "cfphotoeditor://cancel")!) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } compactTrailing: {
                Link(destination: URL(string: "cfphotoeditor://complete")!) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.mint)
                }
            } minimal: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.mint)
            }
            .keylineTint(.mint)
        }
    }

    private func islandAction(
        _ title: String,
        icon: String,
        destination: String,
        tint: Color
    ) -> some View {
        Link(destination: URL(string: "cfphotoeditor://\(destination)")!) {
            Label(title, systemImage: icon)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(tint)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
    }
}
