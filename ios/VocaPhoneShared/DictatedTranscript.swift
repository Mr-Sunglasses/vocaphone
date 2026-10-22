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
/// 2. Chinese script, when the user picked Traditional. Before every stage
///    that reads words, so repair, custom vocabulary and snippets all see the
///    characters the user writes — a custom 軟體 is never compared with the
///    model's 软件. Every route and every style, `raw` included: it is a
///    choice of writing system, not an edit.
/// 3. Repair — the one stage allowed to change the words, and only when the
///    user has left Clean up speech on. It runs before styling because it is
///    what puts the sentence boundaries *there*: styling capitalizes and
///    terminates around boundaries, and cannot find one that is missing.
///    Never for `raw`, which promises the model's own output.
/// 4. Grammar — the optional "Fix grammar (English)" model, after repair
///    because it reads the sentences repair has finished and was trained on
///    punctuated text, and before style so the styler capitalizes and
///    terminates whatever words it settled on. Only for on-device transcripts
///    (a gateway has its own pipeline), never for `raw`, and only for English.
///    It may not touch a custom vocabulary word, a learned word or a snippet
///    trigger; `ProtectedSpans` are masked inside the stage.
/// 5. Style — but only for transcripts produced on this device. A gateway has
///    already applied the writing style the session asked for, and applying it
///    twice is how "Hello." becomes "Hello.." on one route and not the other.
/// 6. Custom vocabulary. After styling, so the user's own capitalization of
///    a name is the last word on it rather than something sentence case
///    overrides; before spoken emoji and digits, which could otherwise turn
///    part of a term into a glyph. Every route, because only Whisper can be
///    prompted with the list. Never for `raw`. One-letter slips are corrected
///    only in English text; other languages get spacing and case.
/// 7. Spoken emoji. After styling, because the styler has to see "emoji" as
///    an ordinary word to capitalize and terminate around it; before digits,
///    because the table's keys are words — "hundred emoji" is 💯, and once
///    digit conversion has made it "100 emoji" there is no key left to find.
///    Applies whichever route produced the transcript: unlike styling, no
///    gateway has done it already.
/// 8. Digits. After styling, never before: the styler capitalizes the first
///    letter of a sentence, so a sentence already reduced to "20 people came"
///    would have it look past the digits and capitalize "People".
/// 9. Snippet expansion, last of all. A trigger's expansion is literal text
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
        chineseScript: ChineseScript = .unchanged,
        snippets: [Snippet] = SnippetStore.snippets,
        snippetExpander: SnippetExpanding = SnippetExpander(),
        vocabulary: [String] = CustomVocabulary.terms(LocalTranscriptionPreferences.customVocabulary),
        isDictionaryWord: (String) -> Bool = EnglishWords.contains,
        grammar: (any GrammarStage)? = nil,
        learnedWords: [String] = []
    ) -> String {
        let cleaned = TraditionalChinese.apply(
            TranscriptSanitizer.clean(raw), script: chineseScript, language: language
        )
        let repaired = repairSpeech && style != .raw
            ? TranscriptRepair.apply(cleaned, language: language)
            : cleaned
        let corrected = if let grammar, !styledUpstream, style != .raw,
            TranscriptRepair.isEnglish(repaired, language: language, isDictionaryWord: isDictionaryWord)
        {
            grammar.correct(
                repaired, keeping: grammarKeeps(vocabulary: vocabulary + learnedWords, snippets: snippets)
            )
        } else {
            repaired
        }
        let styled = styledUpstream
            ? corrected
            : TranscriptStyler.apply(corrected, style: style, language: language)
        // Never for `raw`, on the same grounds as repair: raw promises the
        // model's own output, and a glyph is not something the model said.
        let spelled = style != .raw
            ? VocabularyCorrection.apply(
                styled,
                terms: vocabulary,
                isDictionaryWord: isDictionaryWord,
                // A trigger corrected into a term would never expand. Found by
                // the expander's own pattern, so exactly what it will match.
                protectedRanges: SnippetExpander.triggerRanges(in: styled, using: snippets),
                // The word list that keeps a real word from being taken for a
                // near miss is English; in any other language nothing would.
                nearMisses: !vocabulary.isEmpty && TranscriptRepair.isEnglish(
                    styled, language: language, isDictionaryWord: isDictionaryWord
                )
            )
            : styled
        let emojified = spokenEmoji && style != .raw
            ? SpokenEmoji.glyphs(in: spelled, language: language)
            : spelled
        let digited = numbersAsDigits ? SpokenNumbers.digits(in: emojified) : emojified
        return snippetExpander.expand(in: digited, using: snippets)
    }

    /// Every word of the user's vocabulary, learned words and snippet
    /// triggers, which grammar may not change.
    static func grammarKeeps(vocabulary: [String], snippets: [Snippet]) -> Set<String> {
        Set((vocabulary + snippets.map(\.trigger))
            .flatMap { $0.split(whereSeparator: { !$0.isLetter && !$0.isNumber && $0 != "'" && $0 != "’" }) }
            .map { $0.lowercased() })
    }
}
