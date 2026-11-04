import ActivityKit
import AppIntents
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
                    Text(context.state.status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                Button(intent: CancelPhotoEditorIntent(sessionID: context.attributes.sessionID)) {
                    Label("取消", systemImage: "xmark")
                }
                .buttonStyle(.bordered)
                Button(intent: CompletePhotoEditorIntent(sessionID: context.attributes.sessionID)) {
                    Label("完成", systemImage: "checkmark")
                }
                .buttonStyle(.borderedProminent)
                .tint(.yellow)
                .disabled(!context.state.canComplete)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .activityBackgroundTint(Color.black.opacity(0.88))
            .activitySystemActionForegroundColor(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(.mint)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(spacing: 2) {
                        Text("CF 照片编辑")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                        Text("长按查看取消与完成")
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 10) {
                        Button(intent: CancelPhotoEditorIntent(sessionID: context.attributes.sessionID)) {
                            Label("取消", systemImage: "xmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button(intent: CompletePhotoEditorIntent(sessionID: context.attributes.sessionID)) {
                            Label("完成", systemImage: "checkmark")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.yellow)
                        .disabled(!context.state.canComplete)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Button(intent: CancelPhotoEditorIntent(sessionID: context.attributes.sessionID)) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            } compactTrailing: {
                Button(intent: CompletePhotoEditorIntent(sessionID: context.attributes.sessionID)) {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(context.state.canComplete ? .mint : .gray)
                }
                .disabled(!context.state.canComplete)
            } minimal: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.mint)
            }
            .keylineTint(.mint)
        }
    }
}
