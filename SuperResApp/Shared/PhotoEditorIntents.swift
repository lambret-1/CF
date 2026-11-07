import ActivityKit
import AppIntents
import Foundation

struct CancelPhotoEditorIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "取消照片编辑"
    static var openAppWhenRun: Bool = true
    @Parameter(title: "编辑会话") var sessionID: String

    init() { sessionID = "" }
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        PhotoEditorIntentBridge.send(command: "cancel", sessionID: sessionID)
        if let activity = Activity<PhotoEditorActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        return .result()
    }
}

struct CompletePhotoEditorIntent: LiveActivityIntent {
    static var title: LocalizedStringResource = "完成照片编辑"
    static var openAppWhenRun: Bool = true
    @Parameter(title: "编辑会话") var sessionID: String

    init() { sessionID = "" }
    init(sessionID: String) { self.sessionID = sessionID }

    func perform() async throws -> some IntentResult {
        guard let activity = Activity<PhotoEditorActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == sessionID
        }), activity.content.state.canComplete else {
            return .result()
        }
        let savingState = PhotoEditorActivityAttributes.ContentState(
            status: "正在保存",
            selectedAction: "edit",
            canComplete: false
        )
        await activity.update(
            ActivityContent(state: savingState, staleDate: Date().addingTimeInterval(300))
        )
        PhotoEditorIntentBridge.send(command: "complete", sessionID: sessionID)
        return .result()
    }
}

/// 灵动岛按钮 → 主 App 的唯一通道：App Group 里的 UserDefaults。
/// 扩展与主 App 不在同一进程，NotificationCenter 无法跨进程传递，
/// 主 App 在 scenePhase 变为 active 时读取并消费这条指令。
enum PhotoEditorIntentBridge {
    static func send(command: String, sessionID: String) {
        guard let defaults = UserDefaults(suiteName: PhotoEditorActivityAttributes.appGroupID) else { return }
        defaults.set(command, forKey: PhotoEditorActivityAttributes.commandKey)
        defaults.set(sessionID, forKey: PhotoEditorActivityAttributes.sessionKey)
    }
}
