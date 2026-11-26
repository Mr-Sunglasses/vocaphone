import UIKit

/// Curly quotes, em dashes and ellipses — and the field's right to refuse them.
///
/// `UITextInputTraits` exposes `smartQuotesType`, `smartDashesType` and
/// `smartInsertDeleteType` on the proxy, and fields set them deliberately: a
/// code editor turns smart quotes off precisely so that a keyboard does not curl
/// them into something that will not compile. Honouring the field is both the
/// native behaviour and the respectful one.
///
/// Pure, so every substitution can be checked against its preceding text without
/// a document.
enum SmartPunctuation {
    /// What a substitution does to the document: remove the characters already
    /// typed, then insert the replacement.
    struct Substitution: Equatable {
        let deletions: Int
        let insertion: String
    }

    /// What the field allows, resolved from its own traits.
    struct Traits: Equatable {
        var allowsQuotes = true
        var allowsDashes = true

        static let all = Traits()
        static let none = Traits(allowsQuotes: false, allowsDashes: false)

        @MainActor
        static func resolve(for proxy: UITextDocumentProxy, enabled: Bool) -> Traits {
            guard enabled else { return .none }
            // URL and email fields are typed into by machines as often as by
            // people, and a curled apostrophe in a query string is a broken link.
            switch proxy.keyboardType ?? .default {
            case .URL, .emailAddress, .webSearch, .asciiCapable:
                return .none
            default:
                break
            }
            return Traits(
                allowsQuotes: (proxy.smartQuotesType ?? .default) != .no,
                allowsDashes: (proxy.smartDashesType ?? .default) != .no
            )
        }
    }

    static let leftSingleQuote = "\u{2018}"
    static let rightSingleQuote = "\u{2019}"
    static let leftDoubleQuote = "\u{201C}"
    static let rightDoubleQuote = "\u{201D}"
    static let emDash = "\u{2014}"
    static let ellipsis = "\u{2026}"

    /// The substitution for one typed character, or `nil` to insert it as typed.
    static func substitution(
        for typed: String,
        before: String,
        traits: Traits
    ) -> Substitution? {
        // Anything that smells of a path, a handle, a URL or an identifier is
        // left exactly as typed. Getting this wrong turns working text into
        // text that looks right and no longer works.
        guard !looksLikeCode(before) else { return nil }

        switch typed {
        case "'":
            guard traits.allowsQuotes else { return nil }
            return Substitution(
                deletions: 0,
                insertion: opensQuote(after: before) ? leftSingleQuote : rightSingleQuote
            )
        case "\"":
            guard traits.allowsQuotes else { return nil }
            return Substitution(
                deletions: 0,
                insertion: opensQuote(after: before) ? leftDoubleQuote : rightDoubleQuote
            )
        case "-":
            guard traits.allowsDashes, before.hasSuffix("-"), !before.hasSuffix("--") else {
                return nil
            }
            return Substitution(deletions: 1, insertion: emDash)
        case ".":
            guard traits.allowsDashes, before.hasSuffix(".."), !before.hasSuffix("...") else {
                return nil
            }
            return Substitution(deletions: 2, insertion: ellipsis)
        default:
            return nil
        }
    }

    /// Whether a quote here opens or closes.
    ///
    /// Opening after nothing, after whitespace, or after an opening bracket;
    /// closing after a word or its punctuation — which is what makes "don't"
    /// come out with the right apostrophe without anyone thinking about it.
    static func opensQuote(after before: String) -> Bool {
        guard let last = before.last else { return true }
        if last.isWhitespace { return true }
        return "([{\u{201C}\u{2018}".contains(last)
    }

    /// Whether the token the cursor sits in looks like code rather than prose.
    static func looksLikeCode(_ before: String) -> Bool {
        let token = before.reversed().prefix { !$0.isWhitespace }
        guard !token.isEmpty else { return false }
        return token.contains { "/\\_@#$<>{}[]|~^=".contains($0) }
    }
}

/// Whether the shift key should turn itself on, given what the document says.
///
/// Pure, and separated from the controller for one reason: the decision has a
/// third answer. As well as "on" and "off" there is **"do not touch it"**, and
/// collapsing that into one of the other two is what produced capital letters in
/// the middle of words.
///
/// `UITextDocumentProxy` returns `nil` for its context whenever the host has not
/// answered — while the keyboard is loading, and transiently while the host is
/// mid-update. This code used to read that as `""`, and an empty document is the
/// start of a sentence, so Shift came on. The host answers on most keystrokes
/// and not on others, so the capital landed on whichever letter happened to
/// follow a read the host skipped: "how Are you", "I am The good". Nothing about
/// it looked like a rule, which is exactly why it read as random.
///
/// The rest of this file already knew better — ``WordComposer/reconcile(documentBefore:)``
/// guards on the same `nil` and says so in its own comment. This is the one
/// place that did not.
enum AutomaticShift {
    /// What the keyboard knows about the moment it is deciding in.
    struct Context {
        /// The user's Auto-capitalization switch. Off means Shift only ever
        /// comes on by hand.
        var isEnabled = true
        /// The keyboard has just arrived in this field and nothing has been
        /// typed yet, so "leave it as it is" has nothing worth keeping: the
        /// state on screen belongs to the previous field, or to no field.
        var isArrival = false
        /// `UIKeyInput.hasText`. Read only on arrival, to tell a field that is
        /// empty from a host that has not answered: both hand back `nil`.
        var documentHasText = true
        /// Text after the cursor, when the host gave any.
        var documentAfter: String?
        /// The lock in force was set for a field that asked for capitals, not
        /// by a double tap, so it does not outlive that field.
        var lockIsAutomatic = false
    }

    /// The state to move to, or `nil` to leave the shift key exactly as it is.
    static func state(
        documentBefore: String?,
        autocapitalization: UITextAutocapitalizationType,
        current: ShiftState,
        context: Context = Context()
    ) -> ShiftState? {
        // The field wants everything capitalised, which it can say without the
        // keyboard knowing a thing about the document. This is the field's
        // requirement rather than a typing aid, so the switch does not apply.
        if autocapitalization == .allCharacters { return .locked }
        // A user-engaged caps lock outranks any automatic decision. One the
        // last field asked for does not: it would follow the user into every
        // field after it.
        let userLocked = current == .locked && !context.lockIsAutomatic
        guard !userLocked else { return nil }
        guard context.isEnabled else { return .off }

        guard let before = resolvedBefore(documentBefore, context: context) else {
            // The host did not answer. Mid-typing that is no information at
            // all, so the last decision — made from a context the host *did*
            // answer — stands. On arrival there is no last decision, and a
            // capital nobody asked for is worse than a lowercase letter at
            // what may have been the start of a sentence.
            if context.isArrival || current == .locked { return .off }
            return nil
        }

        switch autocapitalization {
        case .none:
            return .off
        case .words:
            return before.isEmpty || before.last?.isWhitespace == true
                ? .on
                : .off
        default:
            // "e.g. ", "Mr. " and "3. " all end in a full stop and none of them
            // ends a sentence. See `SentenceBoundary`.
            return SentenceBoundary.endsSentence(before) ? .on : .off
        }
    }

    /// The text before the cursor, with the two cases where `nil` can be read
    /// as "nothing there" filled in.
    private static func resolvedBefore(_ before: String?, context: Context) -> String? {
        if let before { return before }
        guard context.isArrival else { return nil }
        // Text after the cursor and none before it: the start of the document.
        if context.documentAfter != nil { return "" }
        // No text anywhere is an empty field. This is only trusted on arrival:
        // mid-typing, a proxy that has stopped answering reports no text too,
        // and believing it is what once capitalised the middle of sentences.
        return context.documentHasText ? nil : ""
    }
}

/// Sentence capitalization that knows an abbreviation from a full stop.
///
/// `updateAutomaticShift` treats ". " as the end of a sentence. So does "e.g. ",
/// "Mr. ", "vs. " and "3. " at the start of a numbered list — and capitalizing
/// after each of them is a small annoyance that arrives several times a day.
enum SentenceBoundary {
    /// Abbreviations that end in a full stop without ending a sentence.
    static let abbreviations: Set<String> = [
        "mr", "mrs", "ms", "dr", "prof", "sr", "jr", "st",
        "e.g", "i.e", "etc", "vs", "approx", "dept", "est",
        "fig", "vol", "p", "pp", "al", "inc", "ltd", "co",
    ]
    // Not "no": "I said no. We" is far commoner than "No. 5", and a sentence
    // that does not get its capital is the worse mistake.

    /// Whether the text before the cursor genuinely ends a sentence.
    static func endsSentence(_ before: String) -> Bool {
        if before.isEmpty { return true }
        if before.hasSuffix("\n") { return true }
        guard before.hasSuffix(". ") || before.hasSuffix("! ") || before.hasSuffix("? ")
        else {
            return before.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        // "!" and "?" are never abbreviations.
        guard before.hasSuffix(". ") else { return true }

        let beforeStop = before.dropLast(2)
        let token = String(beforeStop.reversed().prefix { !$0.isWhitespace }.reversed())
        guard !token.isEmpty else { return true }

        // A numbered list item: "3. " at the start of its line starts an item,
        // not a sentence — though the item itself is usually capitalized
        // anyway, so this only avoids forcing it. Anywhere else a number is
        // the end of a sentence like any word: "I'm 25. My".
        if token.allSatisfy({ $0.isNumber }) {
            let line = beforeStop.dropLast(token.count).reversed().prefix { !$0.isNewline }
            return !line.allSatisfy(\.isWhitespace)
        }
        return !abbreviations.contains(token.lowercased())
    }
}
