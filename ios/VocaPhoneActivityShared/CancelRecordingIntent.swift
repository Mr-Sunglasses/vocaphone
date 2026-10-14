import AppIntents
import Foundation

/// Cancel from the Live Activity, the same way Finish works: a durable write
/// to the shared record, which the containing app hears through the store's
/// Darwin signal and tears down exactly as it does for the keyboard's Cancel.
///
/// The swipe-back screen tells people to leave vocaphone, and from then on the
/// Lock Screen and the Dynamic Island are the only vocaphone surfaces in reach
/// until they are back at the keyboard. Finish was there; Cancel was not.
struct CancelRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Cancel vocaphone recording"
    static let description = IntentDescription(
        "Stops the active vocaphone recording and discards it."
    )

    @Parameter(title: "Session ID")
    var sessionID: String

    init() {}

    init(sessionID: String) {
        self.sessionID = sessionID
    }

    func perform() async throws -> some IntentResult {
        guard let id = UUID(uuidString: sessionID),
              var record = try SharedStore.shared.load(id),
              record.state == .recording
        else { return .result() }

        try record.transition(to: .canceled)
        try SharedStore.shared.save(record)
        return .result()
    }
}
