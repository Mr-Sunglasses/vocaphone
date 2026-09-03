import Foundation

/// Everything that happens to a transcript between the model returning it and
/// the record that the keyboard inserts from.
///
/// One funnel rather than four call sites, because the *order* is load-bearing
/// and was previously only implicit:
///
/// 1. Sanitize. The later stages capitalize sentences and add terminators, and
///    doing that to `[BLANK_AUDIO]` only makes it look more like something the
///    user meant to say.
/// 2. Repair — the one stage allowed to change the words, and only when the
///    user has left Clean up speech on. It runs before styling because it is
///    what puts the sentence boundaries *there*: styling capitalizes and
///    terminates around boundaries, and cannot find one that is missing.
///    Never for `raw`, which promises the model's own output.
/// 3. Style — but only for transcripts produced on this device. A gateway has
///    already applied the writing style the session asked for, and applying it
///    twice is how "Hello." becomes "Hello.." on one route and not the other.
/// 4. Spoken emoji. After styling, because the styler has to see "emoji" as
///    an ordinary word to capitalize and terminate around it; before digits,
///    because the table's keys are words — "hundred emoji" is 💯, and once
///    digit conversion has made it "100 emoji" there is no key left to find.
///    Applies whichever route produced the transcript: unlike styling, no
///    gateway has done it already.
/// 5. Digits. After styling, never before: the styler capitalizes the first
///    letter of a sentence, so a sentence already reduced to "20 people came"
///    would have it look past the digits and capitalize "People".
/// 6. Snippet expansion, last of all. A trigger's expansion is literal text
///    the user wrote themselves — an email address, a signature — and must
///    not be run back through capitalization or digit conversion. Trigger
///    matching is case-insensitive, so it still fires however styling left
///    the source text cased.
enum DictatedTranscript {
    static func finished(
        _ raw: String?,
        style: WritingStyle,
        language: String = "auto",
        styledUpstream: Bool = false,
        repairSpeech: Bool,
        numbersAsDigits: Bool,
        spokenEmoji: Bool,
        snippets: [Snippet] = SnippetStore.snippets,
        snippetExpander: SnippetExpanding = SnippetExpander()
    ) -> String {
        let cleaned = TranscriptSanitizer.clean(raw)
        let repaired = repairSpeech && style != .raw
            ? TranscriptRepair.apply(cleaned, language: language)
            : cleaned
        let styled = styledUpstream
            ? repaired
            : TranscriptStyler.apply(repaired, style: style, language: language)
        // Never for `raw`, on the same grounds as repair: raw promises the
        // model's own output, and a glyph is not something the model said.
        let emojified = spokenEmoji && style != .raw
            ? SpokenEmoji.glyphs(in: styled)
            : styled
        let digited = numbersAsDigits ? SpokenNumbers.digits(in: emojified) : emojified
        return snippetExpander.expand(in: digited, using: snippets)
    }
}
