import ActivityKit
import Foundation

final class LiveActivityManager: @unchecked Sendable {
    static let shared = LiveActivityManager()

    private init() {}

    @MainActor
    func start(sessionID: UUID) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        let attributes = LocalFlowActivityAttributes(
            sessionID: sessionID.uuidString,
            startedAt: Date()
        )
        let content = ActivityContent(
            state: LocalFlowActivityAttributes.ContentState(
                status: "Recording",
                canFinish: true
            ),
            staleDate: nil
        )

        do {
            _ = try Activity.request(
                attributes: attributes,
                content: content,
                pushType: nil
            )
        } catch {
            // Dictation must continue even when Live Activities are disabled or
            // the system declines to present one.
        }
    }

    func update(status: String, canFinish: Bool) {
        let content = ActivityContent(
            state: LocalFlowActivityAttributes.ContentState(
                status: status,
                canFinish: canFinish
            ),
            staleDate: nil
        )
        Task {
            for activity in Activity<LocalFlowActivityAttributes>.activities {
                await activity.update(content)
            }
        }
    }

    func end(status: String, dismissAfter seconds: TimeInterval = 2) {
        let content = ActivityContent(
            state: LocalFlowActivityAttributes.ContentState(
                status: status,
                canFinish: false
            ),
            staleDate: nil
        )
        let dismissalDate = Date().addingTimeInterval(seconds)
        Task {
            for activity in Activity<LocalFlowActivityAttributes>.activities {
                await activity.end(content, dismissalPolicy: .after(dismissalDate))
            }
        }
    }
}
