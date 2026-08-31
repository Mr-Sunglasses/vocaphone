import Foundation

/// What this keyboard instance has typed since the last word boundary.
///
/// iOS gives a keyboard extension no composing region. `UITextDocumentProxy`
/// has `insertText`, `deleteBackward`, `adjustTextPosition` and two context
/// strings — no marked text, no way to underline the word being typed, no way
/// to ask the host what word the cursor is in. So the keyboard keeps its own
/// answer, and replacing a word means deleting it character by character and
/// inserting the replacement.
///
/// The document context is a *window*, not the document: it is bounded, and it
/// can be `nil` while the keyboard is loading. It is therefore used to
/// **reconcile** — on focus change, after a dictation insertion, after a cursor
/// move — never as the primary source. When the two disagree the document wins
/// and the composition resets, because the user may have moved the cursor with
/// a gesture this keyboard never saw.
///
/// Pure and `Equatable`, so every sequence of edits can be checked against a
/// reference string without standing up an extension.
struct WordComposer: Equatable {
    /// Where the current composition came from. Only keystrokes may be
    /// autocorrected: a dictated transcript, an accepted swipe word and a
    /// tapped suggestion have all already been decided by something the user
    /// can see, and second-guessing them is how a keyboard earns its reputation.
    enum Origin: Equatable {
        case typed
        case dictated
        case suggestion
        case swipe
        /// Re-derived from the document after the cursor moved or the user
        /// backspaced past a word boundary. The keyboard knows the letters but
        /// not where they came from, and the word may well have been dictated —
        /// so it completes and offers corrections as chips, but is never
        /// silently replaced.
        case recovered
    }

    private(set) var text = ""
    private(set) var origin: Origin = .typed

    var isEmpty: Bool { text.isEmpty }

    /// Whether this composition may be replaced by an autocorrect. Only the
    /// first condition; ``TypingCandidates`` applies the rest.
    var isAutocorrectable: Bool { origin == .typed && !text.isEmpty }

    /// The characters that keep a composition going. Apostrophes are in because
    /// "don't" is one word; hyphens are out because "well-known" is two words
    /// as far as any spell checker is concerned.
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "'" || character == "\u{2019}"
    }

    /// Feeds one insertion through the composer.
    ///
    /// Multi-character insertions are handled a character at a time, so pasting
    /// or inserting "one two" ends the composition on the space and starts a
    /// fresh one on "two" — the same result as typing it.
    mutating func insert(_ inserted: String, origin newOrigin: Origin = .typed) {
        for character in inserted {
            if Self.isWordCharacter(character) {
                if text.isEmpty { origin = newOrigin }
                text.append(character)
            } else {
                text = ""
                origin = newOrigin
            }
        }
    }

    /// One backspace. An empty composition stays empty rather than trying to
    /// reconstruct the previous word: the keyboard does not know it, and
    /// guessing from the document window is how a composer desynchronises.
    mutating func deleteBackward() {
        guard !text.isEmpty else { return }
        text.removeLast()
        if text.isEmpty { origin = .typed }
    }

    mutating func reset(origin newOrigin: Origin = .typed) {
        text = ""
        origin = newOrigin
    }

    /// Adopts a word wholesale — a swipe result, or a tapped suggestion that the
    /// user may still want to replace with another chip.
    mutating func adopt(_ word: String, origin newOrigin: Origin) {
        text = word
        origin = newOrigin
    }

    /// Re-derives the composition from what the document actually says.
    ///
    /// The document wins, always. The user may have moved the cursor with a
    /// gesture this keyboard never saw, or backspaced past a space and into the
    /// previous word — and a keyboard that cannot follow them there stops
    /// suggesting anything for the rest of the sentence.
    ///
    /// A word recovered this way is marked ``Origin/recovered``: the letters are
    /// known, the provenance is not, and silently replacing text that might have
    /// been dictated is exactly what this subsystem must never do.
    ///
    /// `nil` means iOS did not answer, which is not the same as "the document is
    /// empty" — the proxy returns `nil` while the keyboard is loading, and
    /// discarding a half-typed word on that is a bug the user sees.
    mutating func reconcile(documentBefore: String?) {
        guard let documentBefore else { return }
        let trailing = Self.trailingWord(of: documentBefore)
        guard trailing != text else { return }
        text = trailing
        origin = trailing.isEmpty ? .typed : .recovered
    }

    /// Everything after the last non-word character — the word the cursor sits
    /// at the end of.
    static func trailingWord(of text: String) -> String {
        String(text.reversed().prefix(while: isWordCharacter).reversed())
    }

    // MARK: - Rewriting

    /// The proxy operations that turn the current composition into `replacement`.
    ///
    /// Returned as a plan rather than performed here so that the caller can
    /// apply the whole thing in one run loop turn — the host sees *n* deletions
    /// and one insertion, and interleaving anything else between them is
    /// visible as flicker.
    struct Rewrite: Equatable {
        let deletions: Int
        let insertion: String

        var isEmpty: Bool { deletions == 0 && insertion.isEmpty }
    }

    func rewrite(to replacement: String) -> Rewrite {
        Rewrite(deletions: text.count, insertion: replacement)
    }
}

/// What the document says on either side of the cursor, read once per event.
///
/// Two reasons this is a type rather than two loose strings.
///
/// The first is cost. Every `documentContextBeforeInput` is a synchronous trip
/// to the host application's process, and a single keystroke used to make six
/// or seven of them — one for smart punctuation, one for the composer, one to
/// check the undo offer, then three more once `textDidChange` came back. Reading
/// the pair once and passing it down is the difference between a keystroke that
/// costs one round trip and one that costs seven, on a path where the budget is
/// a display frame.
///
/// The second is ``isMidWord``. The trailing context is the piece this keyboard
/// never read, and it is the only way to tell "the cursor is at the end of the
/// word I am composing" from "the cursor is halfway through a word I can see
/// half of" — a distinction that decides whether an autocorrect is a correction
/// or a corruption.
struct DocumentSnapshot: Equatable {
    var before: String?
    var after: String?

    /// iOS did not answer, which is not the same as an empty document: the proxy
    /// returns nothing while the keyboard is loading, and treating that as "no
    /// text" discards a half-typed word.
    static let unknown = DocumentSnapshot(before: nil, after: nil)

    init(before: String?, after: String? = nil) {
        self.before = before
        self.after = after
    }

    /// Whether a word continues past the cursor.
    ///
    /// `nil` trailing context is treated as "not mid-word": the permissive
    /// answer is the one that keeps autocorrect working in every field that
    /// declines to answer, and the strict one would silently switch the feature
    /// off wherever iOS was slow to reply.
    var isMidWord: Bool {
        guard let first = after?.first else { return false }
        return WordComposer.isWordCharacter(first)
    }
}

/// The word immediately before the cursor, for next-word prediction.
///
/// Deliberately separate from ``WordComposer``: this one *does* read the
/// document window, because a prediction is a guess about what comes next and a
/// stale guess costs nothing, whereas a stale composition costs the user their
/// word.
enum PrecedingWord {
    static func lastWord(in documentBefore: String?) -> String? {
        guard let documentBefore else { return nil }
        let trimmed = documentBefore.reversed().drop { $0.isWhitespace }
        var word = ""
        for character in trimmed {
            guard WordComposer.isWordCharacter(character) else { break }
            word.append(character)
        }
        guard word.contains(where: \.isLetter) else { return nil }
        return String(word.reversed()).lowercased()
    }
}
