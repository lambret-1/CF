import ActivityKit
import Foundation

struct PhotoEditorActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var selectedAction: String
        var canComplete: Bool
    }

    let sessionID: String

    static let appGroupID = "group.com.superres.app"
    static let commandKey = "photoEditor.island.command"
    static let sessionKey = "photoEditor.island.session"
}
