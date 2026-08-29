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
/// 4. Digits. After styling, never before: the styler capitalizes the first
///    letter of a sentence, so a sentence already reduced to "20 people came"
///    would have it look past the digits and capitalize "People".
enum DictatedTranscript {
    static func finished(
        _ raw: String?,
        style: WritingStyle,
        language: String = "auto",
        styledUpstream: Bool = false,
        repairSpeech: Bool,
        numbersAsDigits: Bool
    ) -> String {
        let cleaned = TranscriptSanitizer.clean(raw)
        let repaired = repairSpeech && style != .raw
            ? TranscriptRepair.apply(cleaned, language: language)
            : cleaned
        let styled = styledUpstream
            ? repaired
            : TranscriptStyler.apply(repaired, style: style, language: language)
        guard numbersAsDigits else { return styled }
        return SpokenNumbers.digits(in: styled)
    }
}
