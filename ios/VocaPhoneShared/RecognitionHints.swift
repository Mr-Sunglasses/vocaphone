import Foundation

/// The words a dictation's speech model is told to listen for, and the form
/// each engine takes them in. Mirrored by `RecognitionHints.kt` on Android.
///
/// One list serves every engine. `terms(vocabulary:replacementTargets:contextTerms:)`
/// builds it in ascending order of importance: terms from the text around the
/// cursor first, then the targets of the user's replacements, then the user's
/// own vocabulary, so every engine that has to shorten it cuts from the front
/// and the user's own words are the last to go. Within each source the term
/// its caller ranks first ends up last, so the cut takes a source's least
/// important term first. Today only the vocabulary is filled in; the other two
/// sources are where replacements and on-screen terms will join it.
///
/// What an engine keeps it writes most important first, which for the
/// vocabulary alone is the order the user wrote it: the order the prompt has
/// always had. Order is not free. On `tools/asr-bench`'s `vocab-en` set,
/// writing the same terms reversed moved Whisper's term accuracy by as much
/// as switching the framing did.
///
/// Engines take the list as:
///
/// - Whisper (WhisperKit here, whisper.cpp on Android): a comma-separated
///   prompt that conditions the decoder, `whisperPrompt(_:maximumTokens:tokenCount:)`.
/// - Qwen3-ASR: comma-separated hotwords in its chat prompt, `qwen3Hotwords(_:)`.
/// - Parakeet Unified: hotwords its transducer's beam search boosts while it
///   decodes, `transducerHotwords(_:)`. sherpa-onnx 1.13.8 biases a transducer
///   only through beam search and a BPE vocabulary, which the app bundles for
///   this one model (`LocalModelDescriptor.hotwordVocabularyFile`).
/// - Every other sherpa-onnx family: nothing. The other Parakeets are TDT
///   models, whose beam search on 1.13.8 can drop whole sentences, and the
///   CTC and non-autoregressive families condition on audio alone.
///
/// Every engine still gets `VocabularyCorrection` afterwards, which spells
/// close misses the user's way from the whole vocabulary, whatever was cut here.
enum RecognitionHints {

    /// The whole list's length, in characters, with ", " between terms. It
    /// bounds the context terms only: the user's own words are never dropped
    /// here, only by an engine's own budget.
    static let maximumCharacters = 2_000

    /// Most terms taken from the text around the cursor.
    static let maximumContextTerms = 100

    /// The ordered, deduplicated hint list. Least important first.
    ///
    /// Each argument lists its most important term first: `vocabulary` in the
    /// order the user wrote it, `contextTerms` as the extractor ranked them.
    /// Duplicates are compared case-insensitively, and the user's spelling wins
    /// over a replacement's or the screen's, because the point of the list is
    /// that the user's capitalization is the correct one.
    static func terms(
        vocabulary: [String],
        replacementTargets: [String] = [],
        contextTerms: [String] = []
    ) -> [String] {
        var seen = Set<String>()
        let user = vocabulary.filter { seen.insert($0.lowercased()).inserted }
        let targets = replacementTargets
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { isHintableReplacement($0) && seen.insert($0.lowercased()).inserted }
        let kept = (targets + user).joined(separator: ", ").count
        var context: [String] = []
        var used = 0
        for term in contextTerms {
            let trimmed = term.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, !seen.contains(trimmed.lowercased()) else { continue }
            guard context.count < maximumContextTerms,
                  kept + used + trimmed.count + 2 <= maximumCharacters
            else { break }
            seen.insert(trimmed.lowercased())
            context.append(trimmed)
            used += trimmed.count + 2
        }
        // Appended one list at a time: `a.reversed() + b.reversed()` is
        // ambiguous to the Xcode 26 type checker CI uses.
        var ordered: [String] = []
        ordered.reserveCapacity(context.count + targets.count + user.count)
        ordered.append(contentsOf: context.reversed())
        ordered.append(contentsOf: targets.reversed())
        ordered.append(contentsOf: user.reversed())
        return ordered
    }

    /// A replacement's target that reads like a term rather than a snippet.
    ///
    /// "get hub" → "GitHub" makes GitHub worth listening for. A replacement
    /// that types an email address, a link or a sentence is not a word anyone
    /// says.
    static func isHintableReplacement(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...32).contains(trimmed.count),
              trimmed.contains(where: \.isLetter),
              !trimmed.contains("@"), !trimmed.contains("/"), !trimmed.contains(":")
        else { return false }
        return trimmed.split(whereSeparator: \.isWhitespace).count <= 3
    }

    // MARK: - Whisper

    /// The prompt competes with the audio for the decoder's context window,
    /// and a long one measurably degrades transcription of everything the user
    /// did say. Whisper truncates past its own limit anyway; stopping well
    /// short of it keeps the context spent on speech.
    static let whisperPromptCharacters = 640

    /// The prompt budget for WhisperKit, in tokens: room for a dozen or so
    /// names, and a fraction of a second of decoder passes rather than the
    /// better part of two seconds.
    ///
    /// Characters are the wrong unit there. WhisperKit's decoder has a
    /// 224-token context shared between the prompt and the transcript, keeps
    /// only the *last* 111 prompt tokens, and feeds every one of them through
    /// the decoder a token at a time before the first word of the window, on
    /// every window and every retry. Names are expensive: a 560-character list
    /// was 206 tokens.
    static let whisperKitPromptTokens = 48

    /// The Whisper prompt for `terms`: the terms, comma separated, ending in a
    /// full stop, dropping terms from the front until it fits
    /// `whisperPromptCharacters` and, when given, `maximumTokens` as
    /// `tokenCount` counts them. Empty when nothing fits.
    ///
    /// A bare list, which is what OpenAI documents for vocabulary biasing and
    /// reads to the decoder as a plausible run of text in the same domain as
    /// the speech. A "Glossary: " framing (VocaMac's) was measured against it
    /// on `tools/asr-bench`'s `vocab-en` set and was no better: one term in
    /// 120 worse on each platform in this order, a tie across two orders on
    /// Android. See docs/local-model-review.md.
    ///
    /// Whole terms only: half a name is worse than no name, because it biases
    /// toward a spelling nobody wants. The front of `terms` is where the least
    /// important are (see `terms(vocabulary:replacementTargets:contextTerms:)`);
    /// the terms kept are written most important first.
    static func whisperPrompt(
        _ terms: [String],
        maximumTokens: Int? = nil,
        tokenCount: (String) -> Int = { _ in 0 }
    ) -> String {
        // Most important first, until the next term would pass the character
        // budget. That stops after a few dozen terms however long the list,
        // where rebuilding every shorter list did work that grew with the
        // square of a pasted vocabulary.
        var kept: [String] = []
        var length = 1  // the closing full stop
        for term in terms.reversed() {
            let added = term.count + (kept.isEmpty ? 0 : 2)
            guard length + added <= whisperPromptCharacters else { break }
            kept.append(term)
            length += added
        }
        // Then the token budget, dropping the least important kept term at a
        // time. Bounded by what fits in `whisperPromptCharacters`.
        guard let maximumTokens else { return prompt(kept) }
        while !kept.isEmpty {
            let candidate = prompt(kept)
            if tokenCount(candidate) <= maximumTokens { return candidate }
            kept.removeLast()
        }
        return ""
    }

    private static func prompt(_ terms: [String]) -> String {
        terms.isEmpty ? "" : terms.joined(separator: ", ") + "."
    }

    // MARK: - Qwen3-ASR

    /// Most hotwords Qwen3-ASR is given, and their combined length.
    ///
    /// sherpa-onnx writes them into the system turn of Qwen3-ASR's chat
    /// prompt, which shares a 512-token window with the audio and the
    /// transcript. The app's longest window is 14 seconds, about 180 audio
    /// tokens, and up to 256 transcript tokens for Hindi; 200 characters of
    /// names is about 50 tokens more, which still fits.
    static let maximumHotwords = 20
    static let maximumHotwordCharacters = 200

    /// Qwen3-ASR's hotwords: the terms at the end of `terms`, most important
    /// first and comma separated, as sherpa-onnx's `hotwords` stream option
    /// takes them. Nil when there are none.
    ///
    /// The option is split on ASCII commas, so a comma inside a term becomes
    /// a space.
    static func qwen3Hotwords(_ terms: [String]) -> String? {
        var kept: [String] = []
        var used = 0
        for term in terms.reversed() {
            let term = term.replacingOccurrences(of: ",", with: " ")
                .trimmingCharacters(in: .whitespaces)
            guard !term.isEmpty else { continue }
            guard kept.count < maximumHotwords,
                  used + term.count + 1 <= maximumHotwordCharacters
            else { break }
            kept.append(term)
            used += term.count + 1
        }
        return kept.isEmpty ? nil : kept.joined(separator: ",")
    }

    // MARK: - Transducers

    /// Most hotwords a transducer is given.
    ///
    /// sherpa-onnx builds them into a small prefix tree once per decode, so
    /// the count costs next to nothing; what grows with it is the chance that
    /// some boosted spelling fits a stretch of ordinary speech. `vocab-en`
    /// clips carry six or so terms, and LibriSpeech was measured with all 56
    /// of its terms boosted at once (docs/local-model-review.md); this leaves
    /// a user a little more than that.
    static let maximumTransducerHotwords = 64

    /// How strongly each word piece of a hotword is boosted, in log
    /// probability, and how many hypotheses the beam search keeps. Tuned on
    /// `tools/asr-bench`'s `vocab-en` set with LibriSpeech as the check that
    /// ordinary speech is not respelled; see docs/local-model-review.md.
    static let transducerHotwordScore: Float = 2.0
    static let transducerBeamWidth: Int32 = 4

    /// A transducer's hotwords: the terms at the end of `terms`, most important
    /// first, one phrase each, separated by "/" as sherpa-onnx's per-stream
    /// hotwords take them. Nil when there are none.
    ///
    /// sherpa-onnx reads "/" as the phrase separator and a word that starts
    /// with ":" as a score, and its token lookup reads a word piece starting
    /// with "#" or "@" as a threshold or a label. Measured on 1.13.8, the term
    /// "foo :bar" throws inside sherpa-onnx, which through the C API is a
    /// crash, and "Kanishk #x" cut most of a sentence out of the transcript.
    /// None of the four can be part of a hotword, so each becomes a space,
    /// which splits the term into words the way the speaker would say them.
    static func transducerHotwords(_ terms: [String]) -> String? {
        var kept: [String] = []
        for term in terms.reversed() {
            let cleaned = String(term.map { (character: Character) -> Character in
                "/:#@".contains(character) ? " " : character
            })
            let phrase = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            guard !phrase.isEmpty else { continue }
            guard kept.count < maximumTransducerHotwords else { break }
            kept.append(phrase)
        }
        return kept.isEmpty ? nil : kept.joined(separator: "/")
    }

    /// The hotwords a sherpa-onnx recognizer for `model` decodes with, or nil
    /// for a model that takes none.
    static func sherpaHotwords(for model: LocalModelDescriptor, terms: [String]) -> String? {
        if model.hotwordVocabularyFile != nil { return transducerHotwords(terms) }
        guard model.sherpaFamily == .qwen3Asr else { return nil }
        return qwen3Hotwords(terms)
    }
}
