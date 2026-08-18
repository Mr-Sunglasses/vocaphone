import Foundation

/// The words this feature is judged on.
///
/// Written once and used in both places they appear — the onboarding step and
/// the Privacy settings screen — because a shorter paraphrase in one of them is
/// how the two end up promising different things. Android's
/// `UsageReportingCopyTest` pins the claims that have to survive a copy edit,
/// and `TelemetryParityTest` compares this file against its Kotlin twin
/// word-for-word.
///
/// Held word-for-word alongside `UsageReportingCopy.kt` on Android. Two
/// platforms making subtly different privacy promises about the same pipeline is
/// worse than either promise on its own.
enum UsageReportingCopy {

    static let title = "Help fix what's broken?"

    static let settingsTitle = "Usage reporting"

    static let whatIsSent = """
        VocaPhone is in beta and most problems never get reported. With this on, \
        the app sends a short list of counters — which setup step you reached, \
        whether a dictation succeeded or failed and at which stage, which \
        on-device model you downloaded, which one transcribed your speech and at \
        what accuracy setting, and the app version — to a server VocaHQ runs.
        """

    /// The third sentence is the one worth keeping through every copy review. It
    /// is literally true — Aptabase derives its anonymous user from a salt it
    /// throws away every 24 hours, so nothing is stored on the phone to identify
    /// anyone — it is unusual, and it is what a sceptical reader will actually
    /// weigh.
    static let whatIsNeverSent = """
        It never sends what you say, what you type, your transcripts, your audio, \
        your gateway's address, or your device model. It stores nothing on your \
        phone to identify you, and nothing sent today can be linked to anything \
        sent tomorrow.
        """

    static let optOutIsLogged = """
        Turning this off sends one last event recording that you turned it off, \
        then discards anything still waiting. That final event is how we know how \
        many people opt out.
        """

    static let noIdentifier =
        "There is no reporting ID to reset, because there is never one stored."

    static let turnOn = "Turn on"

    static let notNow = "Not now"

    static let seeWhatIsSent = "See exactly what's sent"

    static let changeLater = "You can change this any time in Settings › Privacy."

    static let emptyQueue = """
        Nothing is waiting to be sent. Events appear here as you use the app, and \
        this screen shows the exact JSON that would be posted — not a summary of it.
        """
}
