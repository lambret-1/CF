import SwiftUI
import PhotosUI
import UIKit
import CoreImage
import UniformTypeIdentifiers
import ActivityKit
import Photos
import PencilKit

extension DemoPhotoAutoEnhanceView {
@MainActor
func startLiveActivity() async {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        for activity in Activity<PhotoEditorActivityAttributes>.activities {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        liveActivity = nil
        let sessionID = UUID().uuidString
        liveActivitySessionID = sessionID
        UserDefaults(suiteName: PhotoEditorActivityAttributes.appGroupID)?.set(sessionID, forKey: "photoEditorLiveActivitySessionID")
        lastLiveActivityCanComplete = false
        let attributes = PhotoEditorActivityAttributes(sessionID: sessionID)
        let state = PhotoEditorActivityAttributes.ContentState(
            status: "未修改",
            selectedAction: "edit",
            canComplete: false
        )
        do {
            liveActivity = try Activity.request(
                attributes: attributes,
                content: ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600)),
                pushType: nil
            )
        } catch {
            liveActivity = nil
            liveActivitySessionID = nil
            alertMessage = "无法启动灵动岛活动：\(error.localizedDescription)"
        }
    }

    @MainActor
func restoreLiveActivity() {
        if liveActivitySessionID == nil {
            liveActivitySessionID = UserDefaults(suiteName: PhotoEditorActivityAttributes.appGroupID)?.string(forKey: "photoEditorLiveActivitySessionID")
        }
        guard let activity = Activity<PhotoEditorActivityAttributes>.activities.first(where: {
            $0.attributes.sessionID == liveActivitySessionID
        }) else { return }
        liveActivity = activity
        liveActivitySessionID = activity.attributes.sessionID
        Task { await updateLiveActivity(canComplete: isCompleteEnabled) }
    }

    @MainActor
func updateLiveActivity(canComplete: Bool) async {
        guard let liveActivity, lastLiveActivityCanComplete != canComplete else { return }
        let state = PhotoEditorActivityAttributes.ContentState(
            status: canComplete ? "已修改" : "未修改",
            selectedAction: "edit",
            canComplete: canComplete
        )
        await liveActivity.update(
            ActivityContent(state: state, staleDate: Date().addingTimeInterval(3600))
        )
        lastLiveActivityCanComplete = canComplete
    }

    @MainActor
func endLiveActivity() async {
        guard let liveActivity else { return }
        await liveActivity.end(nil, dismissalPolicy: .immediate)
        self.liveActivity = nil
        liveActivitySessionID = nil
        lastLiveActivityCanComplete = nil
    }

    func consumeIslandCommand() {
        guard let defaults = UserDefaults(suiteName: PhotoEditorActivityAttributes.appGroupID),
              let command = defaults.string(forKey: PhotoEditorActivityAttributes.commandKey),
              let sessionID = defaults.string(forKey: PhotoEditorActivityAttributes.sessionKey),
              sessionID == liveActivitySessionID else { return }
        defaults.removeObject(forKey: PhotoEditorActivityAttributes.commandKey)
        defaults.removeObject(forKey: PhotoEditorActivityAttributes.sessionKey)
        switch command {
        case "cancel":
            dismiss()
        case "complete":
            saveToPhotos()
        default:
            break
        }
    }
}
