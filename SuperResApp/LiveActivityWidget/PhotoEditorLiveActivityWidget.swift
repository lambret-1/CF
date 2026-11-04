import ActivityKit
import AppIntents
import SwiftUI
import WidgetKit

struct PhotoEditorIslandAction: LiveActivityIntent {
    static var title: LocalizedStringResource = "照片编辑快捷操作"
    @Parameter(title: "操作") var action: String
    @Parameter(title: "编辑会话") var sessionID: String

    init() {
        action = "compare"
        sessionID = ""
    }

    init(action: String, sessionID: String) {
        self.action = action
        self.sessionID = sessionID
    }

    func perform() async throws -> some IntentResult {
        guard let defaults = UserDefaults(suiteName: PhotoEditorActivityAttributes.appGroupID) else {
            return .result()
        }
        defaults.set(action, forKey: PhotoEditorActivityAttributes.commandKey)
        if let activity = Activity<PhotoEditorActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) {
            let status: String
            switch action {
            case "compare": status = "原图对比"
            case "undo": status = "已撤销"
            case "redo": status = "已重做"
            default: status = "正在编辑"
            }
            let state = PhotoEditorActivityAttributes.ContentState(status: status, selectedAction: action)
            await activity.update(ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)))
        }
        return .result()
    }
}

@main
struct PhotoEditorLiveActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: PhotoEditorActivityAttributes.self) { context in
            HStack(spacing: 10) {
                Image(systemName: "slider.horizontal.3").font(.system(size: 19, weight: .semibold)).foregroundStyle(.mint)
                VStack(alignment: .leading, spacing: 3) {
                    Text("CF 照片编辑").font(.system(size: 14, weight: .semibold))
                    Text(context.state.status).font(.system(size: 12)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 4)
                islandAction("原图", icon: "eye", action: "compare", context: context)
                islandAction("撤销", icon: "arrow.uturn.backward", action: "undo", context: context)
                islandAction("重做", icon: "arrow.uturn.forward", action: "redo", context: context)
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
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.status).font(.system(size: 12, weight: .medium)).lineLimit(1).foregroundStyle(.white)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    HStack(spacing: 8) {
                        islandAction("原图", icon: "eye", action: "compare", context: context)
                        islandAction("撤销", icon: "arrow.uturn.backward", action: "undo", context: context)
                        islandAction("重做", icon: "arrow.uturn.forward", action: "redo", context: context)
                    }
                    .padding(.top, 8)
                    .padding(.bottom, 4)
                }
            } compactLeading: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.mint)
            } compactTrailing: {
                Image(systemName: "photo").foregroundStyle(.white)
            } minimal: {
                Image(systemName: "slider.horizontal.3").foregroundStyle(.mint)
            }
            .keylineTint(.mint)
        }
    }

    @ViewBuilder
    private func islandAction(
        _ title: String,
        icon: String,
        action: String,
        context: ActivityViewContext<PhotoEditorActivityAttributes>
    ) -> some View {
        Button(intent: PhotoEditorIslandAction(action: action, sessionID: context.attributes.sessionID)) {
            Label(title, systemImage: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 7)
                .background(Color.white.opacity(0.12), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
