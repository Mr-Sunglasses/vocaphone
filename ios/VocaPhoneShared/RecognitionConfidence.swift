import Foundation

/// Which words a speech engine was unsure of, for the one question
/// `VocabularyCorrection` asks: may these ordinary words be a custom word the
/// engine misheard? "cooper netties" is two real words, and only an engine
/// that was unsure of them is evidence that the speaker said "Kubernetes".
/// Mirrors `RecognitionConfidence.kt`.
///
/// Engines that report a confidence:
///
/// - Whisper (WhisperKit, whisper.cpp): each token's log probability, which
///   decoding computes anyway. A word is the geometric mean of its tokens,
///   which is what WhisperKit's own word timings report. Word timestamps are
///   not turned on for it: their alignment pass costs a decoder run.
/// - The sherpa-onnx transducers (Parakeet, Zipformer): `ys_log_probs` on the
///   iOS bridge. A word is its least sure token, as VocaMac reads Parakeet.
///
/// Every other engine reports nothing, which is not the same as being sure:
/// `lowConfidenceWords` is nil then, and a run of real words is left alone.
struct RecognitionConfidence: Equatable, Sendable {
    /// Below this a word counts as unsure. Whisper's probability for a
    /// clearly spoken common word is usually above 0.9; misheard names and
    /// jargon fall well below it. VocaMac's threshold.
    static let lowThreshold = 0.6

    /// How a word's probability is made from its tokens'.
    enum WordScore: Sendable {
        /// exp(mean log probability): WhisperKit's word probability.
        case geometricMean
        /// The least sure token.
        case minimum
    }

    /// One decoded token: its text as the engine writes it, a leading space
    /// (or "▁") starting a new word, and its natural-log probability.
    struct Token: Equatable, Sendable {
        let text: String
        let logProbability: Float
    }

    private(set) var unsure: Set<String> = []
    private(set) var sure: Set<String> = []
    /// Whether any word carried a probability.
    private(set) var isReported = false

    static let unreported = RecognitionConfidence()

    init() {}

    /// Words built from `tokens` as `score` says.
    init(tokens: [Token], score: WordScore) {
        var words: [(text: String, logProbabilities: [Float])] = []
        for token in tokens {
            if words.isEmpty || Self.startsWord(token.text) {
                words.append((token.text, [token.logProbability]))
            } else {
                words[words.count - 1].text += token.text
                words[words.count - 1].logProbabilities.append(token.logProbability)
            }
        }
        for word in words {
            add(word.text, probability: Self.probability(word.logProbabilities, score: score))
        }
    }

    /// Tokens written by a native bridge one per line, as
    /// `<log probability>\t<token text>`. Lines that do not parse are skipped.
    init(tokenLines: String, score: WordScore) {
        let tokens = tokenLines.split(separator: "\n", omittingEmptySubsequences: true)
            .compactMap { line -> Token? in
                guard let tab = line.firstIndex(of: "\t"),
                      let value = Float(line[..<tab]), value.isFinite
                else { return nil }
                return Token(text: String(line[line.index(after: tab)...]), logProbability: value)
            }
        self.init(tokens: tokens, score: score)
    }

    /// Records one decoded word. A word the engine gave no probability counts
    /// as sure. A word hyphenated or joined by punctuation is recorded as the
    /// words `VocabularyCorrection` will see.
    mutating func add(_ word: String, probability: Double?) {
        if probability != nil { isReported = true }
        for part in VocabularyCorrection.words(in: word) where !part.key.isEmpty {
            if let probability, probability < Self.lowThreshold {
                unsure.insert(part.key)
            } else {
                sure.insert(part.key)
            }
        }
    }

    /// Both decodes' words, as though decoded together: a long recording's
    /// windows, or a chunk's two halves.
    func merging(_ other: RecognitionConfidence) -> RecognitionConfidence {
        var merged = self
        merged.unsure.formUnion(other.unsure)
        merged.sure.formUnion(other.sure)
        merged.isReported = isReported || other.isReported
        return merged
    }

    /// Words (`VocabularyCorrection.key`s) decoded below `lowThreshold`
    /// every time they were heard, or nil when the engine reported nothing.
    ///
    /// The text correction sees has been repaired and styled since the
    /// decode, so a word's position there no longer matches the engine's. A
    /// word heard once unsure and once sure ("pie" twice) is therefore left
    /// out: one unsure occurrence must never vouch for respelling another the
    /// engine was sure of.
    var lowConfidenceWords: Set<String>? {
        isReported ? unsure.subtracting(sure) : nil
    }

    /// A leading space, or SentencePiece's "▁" where an engine passes it on.
    private static func startsWord(_ token: String) -> Bool {
        guard let first = token.first else { return false }
        return first.isWhitespace || first == "\u{2581}"
    }

    private static func probability(_ logProbabilities: [Float], score: WordScore) -> Double {
        switch score {
        case .geometricMean:
            let mean = logProbabilities.reduce(0, +) / Float(logProbabilities.count)
            return Double(exp(mean))
        case .minimum:
            return Double(exp(logProbabilities.min() ?? 0))
        }
    }
}
