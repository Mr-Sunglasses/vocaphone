import Foundation

/// Turns a dictated descriptor followed by the word "emoji" into the glyph:
/// "I'm so sad crying emoji crying emoji" becomes "I'm so sad 😭 😭".
///
/// Deliberately **not** part of ``TranscriptStyler``. That stage documents a
/// contract it has to keep — no style adds, removes, or substitutes a word —
/// and this stage exists to break it, under a switch of its own, exactly as
/// ``TranscriptRepair`` and ``SpokenNumbers`` do. Keeping them apart is what
/// lets the styles still be described honestly in Settings.
///
/// The phrase table is ``EmojiTable``, the same generated file the typing strip
/// reads. What is *not* borrowed from the strip is its fuzzy matching: the
/// strip may offer 💀 for a near-miss on "dead" because a suggestion is an
/// offer the user ignores, while this writes text straight to the cursor.
/// Exact keys only.
///
/// Conservative in the same way ``SpokenNumbers`` is, and for the same reason —
/// the obvious implementation produces text nobody would send:
///
/// * A trigger with no recognized descriptor in front of it is left exactly as
///   spoken. "Send me the emoji" survives untouched; this never guesses.
/// * Only a space or a hyphen joins a descriptor to its trigger. "I'm sad,
///   crying emoji" converts "crying"; "I'm sad, emoji" converts nothing,
///   because a comma ends the phrase rather than being read through.
/// * The longest phrase wins, so "loudly crying emoji" is 😭 and not
///   "loudly 😭".
///
/// English only, which is what the settings copy says. `suggestions.tsv` is
/// generated from the English CLDR annotations, so a Hindi or Japanese
/// transcript matches nothing and passes through untouched rather than being
/// partially mangled.
enum SpokenEmoji {
    /// The words that trigger a lookup. "emojis" is here because people
    /// pluralize it; "emoji" is not itself a key in the table, so a trigger can
    /// never match itself.
    static let triggerWords: Set<String> = ["emoji", "emojis"]

    /// Replaces every `<descriptor> emoji` span with its glyph.
    ///
    /// The span replaced covers the descriptor and the trigger word and nothing
    /// else, which is why there is no spacing or punctuation repair here.
    /// Styling has already run by this point, so the trigger arrives carrying
    /// whatever mark the style put on it — "crying emoji." under Clean,
    /// "crying emoji!" under Excited — and replacing only the words leaves that
    /// mark, and the spaces on either side, exactly where they were. That also
    /// makes the stage correct in scripts that do not put a space between
    /// sentences, without needing to know which script it is in.
    static func glyphs(in text: String) -> String {
        // Almost every transcript has no trigger in it at all, and this stage
        // runs on every one of them, so the "nothing to do" case is the one
        // worth being cheap. Everything below — masking, tokenizing, the walk —
        // is skipped for a transcript that cannot contain the trigger.
        //
        // The test is one byte: "emoji" contains a "j", so text with no "j" in
        // it cannot contain "emoji". That is strictly weaker than the
        // word-boundary rule further down, so it can only skip work that was
        // going to find nothing. `| 0x20` folds the ASCII case, and matches
        // exactly "J" and "j" — no UTF-8 continuation byte is below 0x80, so a
        // multi-byte character cannot collide with it. Foundation's
        // `range(of:options:.caseInsensitive)` does the same job correctly but
        // full Unicode case folding measured ~100x the cost of this, enough to
        // make the check dearer than the work it was avoiding.
        guard !text.isEmpty,
              text.utf8.contains(where: { $0 | 0x20 == 0x6A }),
              !EmojiTable.triggers.isEmpty
        else { return text }

        // Masked so a descriptor cannot be eaten out of an address:
        // "crying emoji.com" is a hostname, not a trigger.
        let spans = ProtectedSpans.mask(text)
        let string = spans.text as NSString
        let words = wordPattern.matches(
            in: spans.text,
            range: NSRange(location: 0, length: string.length)
        )
        guard !words.isEmpty else { return text }

        var result = ""
        var copied = 0
        for index in words.indices {
            guard triggerWords.contains(string.substring(with: words[index].range).lowercased())
            else { continue }
            guard let match = descriptor(before: index, in: words, text: string),
                  match.start.location >= copied
            else { continue }
            result += string.substring(with: NSRange(
                location: copied, length: match.start.location - copied
            ))
            result += match.glyph
            copied = words[index].range.upperBound
        }
        guard copied > 0 else { return text }
        result += string.substring(from: copied)
        return spans.restore(result)
    }

    /// Walks backwards from the trigger, growing a candidate key one word at a
    /// time and remembering the longest one the table knows.
    ///
    /// The walk is bounded by the table's own widest key rather than by a word
    /// count, because a key has had its spaces removed and cannot say how many
    /// words built it. Growing past that length can only produce keys the table
    /// does not contain.
    private static func descriptor(
        before trigger: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> (glyph: String, start: NSRange)? {
        var best: (glyph: String, start: NSRange)?
        var key = ""
        var index = trigger - 1
        while index >= 0, isJoiner(gapAfter: index, in: words, text: text) {
            key = text.substring(with: words[index].range).lowercased() + key
            if key.count > EmojiTable.widestKeyLength { break }
            if let glyph = EmojiTable.glyph(forKey: key) {
                best = (glyph, words[index].range)
            }
            index -= 1
        }
        return best
    }

    /// Whether the gap between this word and the next one is nothing but a
    /// space or a hyphen. Any punctuation in between ends the phrase: "sad,
    /// crying emoji" is two clauses, whatever the words concatenate to.
    private static func isJoiner(
        gapAfter index: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> Bool {
        let gap = text.substring(with: NSRange(
            location: words[index].range.upperBound,
            length: words[index + 1].range.location - words[index].range.upperBound
        ))
        return gap == " " || gap == "-" || gap == "‑"
    }

    /// Letters only, so a placeholder left by ``ProtectedSpans`` — which is
    /// digits between two private-use scalars — is invisible to the walk.
    private static let wordPattern = try! NSRegularExpression(
        pattern: "[A-Za-z]+(?:['’][A-Za-z]+)*"
    )
}
