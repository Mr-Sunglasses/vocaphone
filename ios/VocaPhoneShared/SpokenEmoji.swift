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
/// * The whole descriptor or nothing. A proper suffix of what was said is
///   not enough: "smiling face with heart eyes emoji" must not become
///   "smiling face with 😍". Either the contiguous span before the trigger
///   is an exact table key (after the same with/and/of dropping the catalog
///   generator uses), or the words stay as spoken.
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

    /// Words the catalog generator drops when it concatenates a multi-word
    /// Unicode or CLDR name into a strip key. Mirrored here so a spoken form
    /// that still contains them ("smiling face with heart eyes") hits the same
    /// key (`smilingfacehearteyes`) the table actually stores.
    private static let nameStop: Set<String> = [
        "with", "and", "of", "the", "a", "in", "on", "at", "to", "for", "or",
    ]

    /// Keys the typing strip may keep but this stage must not write.
    ///
    /// `korea` in suggestions.tsv is 🇰🇵 (DPRK). Someone saying "korea emoji"
    /// almost never means that flag — they mean the peninsula, or South Korea.
    /// Refuse the bare word on the spoken path only; `southkorea` and
    /// `northkorea` still convert, and the strip is unchanged.
    private static let spokenBlocklist: Set<String> = ["korea"]

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
    static func glyphs(in text: String, language: String = "auto") -> String {
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
        var previousWasGlyph = false
        for index in words.indices {
            guard triggerWords.contains(string.substring(with: words[index].range).lowercased())
            else { continue }
            guard let match = descriptor(before: index, in: words, text: string),
                  match.start.location >= copied
            else { continue }
            let between = string.substring(with: NSRange(
                location: copied, length: match.start.location - copied
            ))
            result += previousWasGlyph ? separating(between) : between
            result += match.glyph
            copied = words[index].range.upperBound
            previousWasGlyph = true
        }
        guard copied > 0 else { return text }
        result += closing(string.substring(from: copied), language: language, source: text)
        return spans.restore(result)
    }

    /// The text after the final glyph, with a sentence terminator that is all
    /// it consists of dropped.
    ///
    /// The styler ends a sentence because a sentence needs an end, and it did
    /// that while the last word was still "emoji". An emoji *is* the end:
    /// people write "I'm so sad 😭" and "💯", not "I'm so sad 😭." — the glyph
    /// does the job the full stop was there to do.
    ///
    /// Only the terminator goes, never an exclamation or a question mark, for
    /// exactly the reason ``TranscriptStyler``'s casual style already gives for
    /// dropping one and keeping the others: a full stop is structure, while "!"
    /// and "?" carry meaning that was in what the user said. So Excited still
    /// ends "😭!" and a dictated question still ends "😭?".
    ///
    /// Only when the terminator is the *whole* tail. "crying emoji is how I
    /// feel." keeps its full stop, because that one is ending a sentence the
    /// glyph merely started.
    private static func closing(_ tail: String, language: String, source: String) -> String {
        let punctuation = SentencePunctuation.resolve(language: language, text: source)
        // Thai and Lao end a sentence with nothing at all, so there is no mark
        // to drop and an empty terminator would match every tail.
        // Newlines count as whitespace here, because Kotlin's `trim` counts
        // them and these two are expected to agree character for character.
        guard !punctuation.terminator.isEmpty,
              tail.trimmingCharacters(in: .whitespacesAndNewlines) == punctuation.terminator
        else { return tail }
        return ""
    }

    /// What to put between two glyphs this stage produced, given the text that
    /// was between their phrases.
    ///
    /// Somebody dictating three emoji in a row pauses between them, and a
    /// speech model writes a pause down as a comma: "crying emoji, crying
    /// emoji, crying emoji" is what the transcript says, and substituting each
    /// phrase in place leaves "😭, 😭, 😭". Nobody punctuates a run of emoji —
    /// they are written "😭 😭 😭" — so when nothing but marks and space
    /// separates two of them, that collapses to a single space.
    ///
    /// Deliberately narrow. It applies only between two glyphs this call just
    /// inserted, never to punctuation anywhere else in the transcript: a comma
    /// after the last emoji still belongs to the sentence that continues past
    /// it, and "fire emoji, then home" keeps its comma. A terminator counts as
    /// well as a separator, because a longer pause is written down as a full
    /// stop and "😭. 😭." is no more something a person types than "😭, 😭".
    private static func separating(_ between: String) -> String {
        guard !between.isEmpty,
              between.allSatisfy({ $0.isWhitespace || SentencePunctuation.universalMarks.contains($0) })
        else { return between }
        return " "
    }

    /// The contiguous joiner-connected words immediately before the trigger,
    /// converted only when that whole span is an exact table key.
    ///
    /// Walks backwards while a space or hyphen joins, stopping at another
    /// trigger word so "crying emoji fire emoji" still finds each descriptor
    /// on its own. No suffix fallback: if only a proper suffix of the span is
    /// a key, the whole phrase is left unchanged — that is what used to type
    /// "smiling face with 😍" for "smiling face with heart eyes emoji".
    ///
    /// The catalog generator drops a small set of name-stop words (with, and,
    /// of, …) when it builds keys, so "smiling face with heart eyes" is stored
    /// as `smilingfacehearteyes`. Looking the span up both raw and with those
    /// stops removed keeps spoken forms aligned with that table without going
    /// back to longest-suffix matching. Leading stops stay in the transcript
    /// ("and fire emoji" keeps "and").
    private static func descriptor(
        before trigger: Int,
        in words: [NSTextCheckingResult],
        text: NSString
    ) -> (glyph: String, start: NSRange)? {
        var parts: [(word: String, range: NSRange)] = []
        var fullLength = 0
        var index = trigger - 1
        while index >= 0, isJoiner(gapAfter: index, in: words, text: text) {
            let raw = text.substring(with: words[index].range).lowercased()
            if triggerWords.contains(raw) { break }
            if fullLength + raw.count > EmojiTable.widestKeyLength { break }
            parts.insert((raw, words[index].range), at: 0)
            fullLength += raw.count
            index -= 1
        }
        guard !parts.isEmpty else { return nil }

        let fullKey = parts.map(\.word).joined()
        if let glyph = glyphForSpoken(fullKey) {
            return (glyph, parts[0].range)
        }

        let significant = parts.filter { !nameStop.contains($0.word) }
        guard !significant.isEmpty else { return nil }
        let strippedKey = significant.map(\.word).joined()
        guard strippedKey != fullKey else { return nil }
        guard let glyph = glyphForSpoken(strippedKey) else { return nil }
        return (glyph, significant[0].range)
    }

    /// Table lookup for the spoken path, with the few keys this stage must not
    /// write even though the typing strip still offers them.
    private static func glyphForSpoken(_ key: String) -> String? {
        if spokenBlocklist.contains(key) { return nil }
        return EmojiTable.glyph(forKey: key)
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

    /// Letters and digits: "100 emoji" is 💯, and a speech model writes
    /// someone saying "hundred" as "100" about as often as it writes the word.
    ///
    /// Digits are why the lookbehind is here. A placeholder left by
    /// ``ProtectedSpans`` is its index between two private-use scalars, so
    /// allowing digits makes the index itself look like a word — and a masked
    /// price or URL would start offering its own index as a descriptor. The
    /// lookbehind stops a word beginning immediately after the opening scalar.
    ///
    /// A multi-digit index can still be entered one character in, and that is
    /// harmless: the closing scalar sits between it and whatever follows, so
    /// the joiner test above ends the phrase before the walk can use it.
    private static let wordPattern = try! NSRegularExpression(
        pattern: "(?<!\u{E000})[A-Za-z0-9]+(?:['’][A-Za-z0-9]+)*"
    )
}
