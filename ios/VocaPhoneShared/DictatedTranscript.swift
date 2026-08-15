import Foundation

/// Everything that happens to a transcript between the model returning it and
/// the record that the keyboard inserts from.
///
/// One funnel rather than three call sites, because the *order* is load-bearing
/// and was previously only implicit:
///
/// 1. Sanitize. The styler capitalizes sentences and adds terminators, and
///    doing that to `[BLANK_AUDIO]` only makes it look more like something the
///    user meant to say.
/// 2. Style — but only for transcripts produced on this device. A gateway has
///    already applied the writing style the session asked for, and applying it
///    twice is how "Hello." becomes "Hello.." on one route and not the other.
/// 3. Digits. After styling, never before: the styler capitalizes the first
///    letter of a sentence, so a sentence already reduced to "20 people came"
///    would have it look past the digits and capitalize "People".
enum DictatedTranscript {
    static func finished(
        _ raw: String?,
        style: WritingStyle? = nil,
        language: String = "auto",
        numbersAsDigits: Bool
    ) -> String {
        let cleaned = TranscriptSanitizer.clean(raw)
        let styled = style.map {
            TranscriptStyler.apply(cleaned, style: $0, language: language)
        } ?? cleaned
        guard numbersAsDigits else { return styled }
        return SpokenNumbers.digits(in: styled)
    }
}
