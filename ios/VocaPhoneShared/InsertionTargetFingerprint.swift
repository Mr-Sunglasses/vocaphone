import CryptoKit
import Foundation

/// A one-way fingerprint of the text field a dictation was started in.
///
/// The keyboard releases its insertion target on every appearance, because iOS
/// reissues document identifiers across an app switch and across a relaunch of
/// the extension (see ``InsertionTarget``). That made the target guard pass for
/// *any* field the keyboard next appeared in: dictate in Messages, switch to
/// Notes while the transcript is on its way, and it inserted itself into Notes.
///
/// What does survive an app switch is the text around the cursor. A keyboard
/// that adopts a session in a later appearance compares the field it is in now
/// with this fingerprint, taken when the dictation started, and parks the
/// transcript behind "Insert in this field" when they differ.
///
/// Only a salted, truncated SHA-256 is stored, never the text: the record lives
/// in the App Group, and the field the user was typing in is not the keyboard's
/// to keep. The session ID salts it, so the same text in two sessions does not
/// produce the same value.
///
/// Limits, on purpose: two fields with the same text around the cursor — two
/// empty fields, most often — look the same, and the transcript follows the
/// cursor as it did before. iOS gives a keyboard no public way to name its host
/// app, and the document identifier changes too often to help.
enum InsertionTargetFingerprint {
    /// Characters taken from each side of the cursor. Short enough to sit
    /// inside the bounded context iOS hands a keyboard, so a host that trims
    /// that context differently on a second read still produces the same value.
    static let contextLength = 24

    /// Nil when iOS did not answer for either side of the cursor, which is not
    /// the same as an empty field (see ``DocumentSnapshot``).
    static func make(sessionID: UUID, before: String?, after: String?) -> String? {
        guard before != nil || after != nil else { return nil }
        let tail = String((before ?? "").suffix(contextLength))
        let head = String((after ?? "").prefix(contextLength))
        let material = [sessionID.uuidString.lowercased(), tail, head].joined(separator: "\u{0}")
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    enum Match: Equatable {
        /// The same field, or a record with no fingerprint to compare — which
        /// keeps the behaviour every earlier record had.
        case same
        /// Evidence of a different field.
        case different
        /// The field could not be read yet. Neither insert nor park; look again.
        case unknown
    }

    static func compare(recorded: String?, current: String?) -> Match {
        guard let recorded else { return .same }
        guard let current else { return .unknown }
        return recorded == current ? .same : .different
    }
}

/// What the keyboard does with a transcript that is waiting for a field.
///
/// Pulled out of the controller, which no test can host, because it decides
/// the two failures this product is worst at: a transcript landing in the wrong
/// app, and one landing twice.
enum PendingTranscriptPolicy {
    enum Action: Equatable {
        /// Insert it now.
        case insert
        /// `readyToInsert` → `targetContextChanged`: this is not its field.
        case park
        /// `targetContextChanged` → `readyToInsert`: back in its field. Decide
        /// again from there.
        case rearm
        /// Leave the state alone and show the bar, Insert button included.
        case offer
    }

    /// Whether a transcript may go in without a tap, when everything else
    /// says it is in the right field. A dictation from Shortcuts or the Action
    /// button was started with no field at all, so the field the keyboard next
    /// appears in is a guess — it might be a search box — and the transcript
    /// is offered there behind Insert instead.
    static func autoInserts(_ record: SessionRecord, preference: Bool) -> Bool {
        preference && !record.isFromShortcut
    }

    /// - Parameters:
    ///   - target: the fingerprint comparison, or `.same` once this appearance
    ///     has confirmed the field.
    ///   - sameDocument: ``InsertionTarget/allowsInsertion(target:current:)``
    ///     for the cursor's movements this appearance has watched.
    ///   - interrupted: ``SessionRecord/insertionInterrupted``.
    static func action(
        for state: SessionState,
        target: InsertionTargetFingerprint.Match,
        sameDocument: Bool,
        interrupted: Bool,
        autoInsert: Bool
    ) -> Action {
        switch state {
        case .targetContextChanged:
            return target == .same && sameDocument ? .rearm : .offer
        case .readyToInsert:
            // An interrupted insertion may have put the text in the field, and
            // that alone changes the text around the cursor: a fingerprint
            // mismatch cannot tell "already inserted here" from "another
            // field". Parking would trade "may have been interrupted" for
            // "Insert in this field", so it stays behind its own warning.
            if interrupted { return .offer }
            if target == .different || (target == .same && !sameDocument) { return .park }
            // An unread field is not evidence either way: it waits for a tap.
            guard target == .same, autoInsert else { return .offer }
            return .insert
        default:
            return .offer
        }
    }
}
