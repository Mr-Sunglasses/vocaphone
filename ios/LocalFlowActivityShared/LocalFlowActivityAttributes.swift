import ActivityKit
import Foundation

struct LocalFlowActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var canFinish: Bool
    }

    let sessionID: String
    let startedAt: Date
}
