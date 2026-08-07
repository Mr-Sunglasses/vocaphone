import AppIntents
import Foundation

struct FinishRecordingIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Finish vocaphone recording"
    static let description = IntentDescription(
        "Stops the active vocaphone recording and starts private transcription."
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

        try record.transition(to: .finalizing)
        try SharedStore.shared.save(record)
        return .result()
    }
}
