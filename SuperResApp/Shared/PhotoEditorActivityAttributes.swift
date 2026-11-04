import ActivityKit
import Foundation

struct PhotoEditorActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var selectedAction: String
        var canComplete: Bool

        private enum CodingKeys: String, CodingKey {
            case status
            case selectedAction
            case canComplete
        }

        init(status: String, selectedAction: String, canComplete: Bool) {
            self.status = status
            self.selectedAction = selectedAction
            self.canComplete = canComplete
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            status = try container.decode(String.self, forKey: .status)
            selectedAction = try container.decode(String.self, forKey: .selectedAction)
            canComplete = try container.decodeIfPresent(Bool.self, forKey: .canComplete) ?? false
        }
    }

    let sessionID: String

    static let appGroupID = "group.com.superres.app"
    static let commandKey = "photoEditor.island.command"
    static let sessionKey = "photoEditor.island.session"
}
