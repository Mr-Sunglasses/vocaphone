import Foundation

/// Keeps offline encoders away from unbounded long-recording sequences. The
/// boundary search prefers a sustained quiet run around ten seconds and retains
/// context on every boundary so low-energy phonemes are not lost.
enum SherpaLongAudio {
    static let sampleRate = 16_000
    static let longAudioThresholdSeconds = 12
    static let targetChunkSeconds = 10
    static let maxChunkSeconds = 14
    static let overlapSamples = sampleRate / 2
    static let silenceOverlapSamples = sampleRate / 5
    /// A chunk shorter than this answering with no tokens is ordinary rather
    /// than a loss: it is the half second of retained overlap a recording that
    /// ends just after a boundary leaves behind, or a fragment of a word.
    /// Longer than this and an empty answer is suspicious — which is why it is
    /// also the bar `SherpaEmptyChunkRecovery` uses before it bothers retrying
    /// a chunk as two halves.
    static let minimumSuspectChunkSamples = 6 * sampleRate
    static let streamingWindowSeconds = targetChunkSeconds + 2

    struct Chunk {
        let start: Int
        let endExclusive: Int
        let overlapsPrevious: Bool
    }

    struct StreamingSplit {
        let endExclusive: Int
        let nextStart: Int
    }

    private static let silenceFrameSamples = sampleRate / 10
    private static let silenceRunFrames = 3
    private static let silenceSearchSamples = sampleRate * 2
    private static let minChunkSamples = sampleRate * 4
    private static let minSilenceRMS = 0.0125
    private static let silenceRMSRatio = 0.18
    private static let silentFrameRMS = 0.006

    static func chunks(_ samples: [Float]) -> [Chunk] {
        guard samples.count > longAudioThresholdSeconds * sampleRate else {
            return [Chunk(start: 0, endExclusive: samples.count, overlapsPrevious: false)]
        }

        let target = targetChunkSeconds * sampleRate
        let maximum = maxChunkSeconds * sampleRate
        var result: [Chunk] = []
        var start = 0
        var overlapsPrevious = false

        while start < samples.count {
            let remaining = samples.count - start
            if remaining <= target {
                result.append(Chunk(start: start, endExclusive: samples.count, overlapsPrevious: overlapsPrevious))
                break
            }

            let idealEnd = min(start + target, samples.count)
            let silence = findSilenceBoundary(
                samples: samples,
                idealEnd: idealEnd,
                minEnd: start + minChunkSamples,
                maxEnd: min(start + maximum, samples.count - minChunkSamples)
            )
            let end = silence ?? idealEnd
            let retainedSamples = silence == nil ? overlapSamples : silenceOverlapSamples
            result.append(Chunk(start: start, endExclusive: end, overlapsPrevious: overlapsPrevious))
            start = max(end - retainedSamples, start + 1)
            overlapsPrevious = true
        }
        return result
    }

    /// Returns a stable prefix once enough future audio exists to search for a
    /// quiet boundary. The caller retains `nextStart` for the next decode.
    static func nextStreamingSplit(_ samples: [Float]) -> StreamingSplit? {
        let target = targetChunkSeconds * sampleRate
        guard samples.count >= streamingWindowSeconds * sampleRate else { return nil }

        let silence = findSilenceBoundary(
            samples: samples,
            idealEnd: target,
            minEnd: minChunkSamples,
            maxEnd: streamingWindowSeconds * sampleRate
        )
        let end = silence ?? target
        let retainedSamples = silence == nil ? overlapSamples : silenceOverlapSamples
        return StreamingSplit(endExclusive: end, nextStart: max(end - retainedSamples, 1))
    }

    private static func findSilenceBoundary(
        samples: [Float], idealEnd: Int, minEnd: Int, maxEnd: Int
    ) -> Int? {
        let first = max(idealEnd - silenceSearchSamples, minEnd)
            / silenceFrameSamples * silenceFrameSamples
        let last = min(idealEnd + silenceSearchSamples, maxEnd, samples.count - silenceFrameSamples)
            / silenceFrameSamples * silenceFrameSamples
        guard first <= last else { return nil }

        var levels: [(Int, Double)] = []
        var peak = 0.0
        var frame = first
        while frame <= last {
            let value = rms(samples, start: frame, endExclusive: frame + silenceFrameSamples)
            peak = max(peak, value)
            levels.append((frame, value))
            frame += silenceFrameSamples
        }
        let threshold = max(minSilenceRMS, peak * silenceRMSRatio)
        var best: Int?
        guard levels.count >= silenceRunFrames else { return nil }
        for start in 0...(levels.count - silenceRunFrames) {
            let run = levels[start..<(start + silenceRunFrames)]
            guard run.allSatisfy({ $0.1 <= threshold }) else { continue }
            let boundary = run.first!.0 + silenceFrameSamples * silenceRunFrames / 2
            if best == nil || abs(boundary - idealEnd) < abs(best! - idealEnd) {
                best = boundary
            }
        }
        return best.map { min(max($0, minEnd), maxEnd) }
    }

    private static func rms(_ samples: [Float], start: Int, endExclusive: Int) -> Double {
        guard endExclusive > start else { return 0 }
        var sum = 0.0
        for value in samples[start..<endExclusive] {
            let sample = Double(value)
            sum += sample * sample
        }
        return (sum / Double(endExclusive - start)).squareRoot()
    }

    /// The loudest 100 ms frame in `samples`, as RMS.
    static func loudestFrame(_ samples: [Float]) -> Double {
        var maximum = 0.0
        var start = 0
        while start < samples.count {
            maximum = max(
                maximum,
                rms(samples, start: start, endExclusive: min(start + silenceFrameSamples, samples.count))
            )
            start += silenceFrameSamples
        }
        return maximum
    }

    /// Whether there is nothing here worth handing to a model.
    ///
    /// The floor is deliberately below the boundary-search silence threshold:
    /// it skips only near-digital-silence and keeps quiet speech. Erring this
    /// way costs a decode of a pause; erring the other way drops speech, which
    /// is the whole failure this file exists to avoid.
    static func isEffectivelySilent(_ samples: [Float]) -> Bool {
        samples.isEmpty || isEffectivelySilent(loudestFrame: loudestFrame(samples))
    }

    static func isEffectivelySilent(loudestFrame: Double) -> Bool {
        loudestFrame < silentFrameRMS
    }

    /// The part of `chunk` that is not inherited from the window before it.
    ///
    /// A chunk that overlaps its predecessor begins with audio that predecessor
    /// already decoded. Everything a later window can *lose* is what comes after
    /// that, so it is what the emptiness of its answer has to be judged on.
    static func newRegion(of samples: [Float], chunk: Chunk, previousEnd: Int) -> [Float] {
        let start = min(max(chunk.start, previousEnd), chunk.endExclusive)
        return Array(samples[start..<chunk.endExclusive])
    }

    /// Whether an empty answer for `newRegion` is a loss worth spending decodes
    /// on, rather than the ordinary silence at the end of a recording.
    ///
    /// It must carry speech next to what the recording has already been heard to
    /// contain, so a trailing pause is not amplified into a retry.
    ///
    /// `inheritsAudio` is what the length bar is for, and why it does not always
    /// apply. A window that begins inside the one before it has to be told apart
    /// from that retained overlap, and below the widest overlap the chunker ever
    /// retains it cannot be — a recording ending just after a boundary leaves
    /// exactly such a tail, a fragment of a word at best. A window that inherited
    /// nothing has no overlap to be confused with: it is the whole of what the
    /// user has said, and a two-word dictation is short precisely because that is
    /// all there was to say. Applying the bar there was what stopped "yes" from
    /// ever being retried.
    static func carriesRecoverableSpeech(
        newRegion: [Float],
        inheritsAudio: Bool,
        loudestFrame: Double,
        loudestFrameSoFar: Double
    ) -> Bool {
        guard !inheritsAudio || newRegion.count > overlapSamples else { return false }
        return carriesSpeech(loudestFrame: loudestFrame, loudestFrameSoFar: loudestFrameSoFar)
    }

    /// Whether `samples` carries speech rather than the room between sentences.
    ///
    /// `loudestFrameSoFar` is the loudest frame heard earlier in the same
    /// recording. No absolute floor separates a quiet room from quiet speech —
    /// one room's noise sits above another room's whisper — but the distance
    /// between a pause and the speech around it holds across recordings, which
    /// is why the boundary search scales its own threshold the same way.
    ///
    /// Only asked about a chunk that already decoded to nothing, and only to
    /// decide whether that is worth re-reading the whole file over. Room tone
    /// answering with no tokens is not a loss; it is the correct answer.
    static func carriesSpeech(loudestFrame: Double, loudestFrameSoFar: Double) -> Bool {
        loudestFrame >= max(silentFrameRMS, loudestFrameSoFar * silenceRMSRatio)
    }
}

/// A decoded chunk, and the language the model said it was.
///
/// Only SenseVoice fills the language in — it decodes a `<|en|>`-style tag as
/// its first token. The other families leave it empty, and the writing styles
/// then fall back to inspecting the text, exactly as they always have.
struct SherpaTranscript: Sendable, Equatable {
    let text: String
    let language: String

    init(text: String, language: String = "") {
        self.text = text
        self.language = language
    }

    static let empty = SherpaTranscript(text: "")

    /// The first language anything reported wins; later chunks rarely disagree.
    func appending(_ next: SherpaTranscript, deduplicateOverlap: Bool) -> SherpaTranscript {
        SherpaTranscript(
            text: SherpaTranscriptMerger.append(
                existing: text, next: next.text, deduplicateOverlap: deduplicateOverlap
            ),
            language: language.isEmpty ? next.language : language
        )
    }

    /// Turns SenseVoice's `<|en|>` token into `en`.
    ///
    /// Anything that does not look like a language code becomes empty rather
    /// than being passed on: the first token is a language tag by convention and
    /// not by guarantee, and a bogus code would pick the wrong punctuation with
    /// more confidence than no code at all.
    static func languageCode(_ raw: String?) -> String {
        var trimmed = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<|"), trimmed.hasSuffix("|>"), trimmed.count > 4 {
            trimmed = String(trimmed.dropFirst(2).dropLast(2))
        }
        trimmed = trimmed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (2...3).contains(trimmed.count), trimmed.allSatisfy(\.isLetter) else { return "" }
        return trimmed.lowercased()
    }
}

/// Joins text from overlapped chunks without writing the repeated boundary words.
enum SherpaTranscriptMerger {
    // The audio overlap is half a second at most, whether it came from a chunk
    // boundary or from the recovery split. A wider text match than that half
    // second can hold cannot be duplicated audio; it can only be a phrase the
    // speaker genuinely repeated, and deleting it is the worse error. Android's
    // `SherpaTranscriptMerger` uses the same bound for the same reason.
    private static let maximumOverlapWords = 4
    /// The same bound for scripts written without spaces, where half a second
    /// of speech is a few characters rather than a few words.
    private static let maximumOverlapCharacters = 6

    static func append(existing: String, next: String, deduplicateOverlap: Bool = true) -> String {
        let left = existing.trimmingCharacters(in: .whitespacesAndNewlines)
        let right = next.trimmingCharacters(in: .whitespacesAndNewlines)
        if left.isEmpty { return right }
        if right.isEmpty { return left }
        if !deduplicateOverlap { return join(left, right) }

        if left.contains(where: { $0.isWhitespace }) || right.contains(where: { $0.isWhitespace }) {
            let leftWords = left.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let rightWords = right.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let maximum = min(maximumOverlapWords, leftWords.count, rightWords.count)
            let overlap = maximum > 0
                ? stride(from: maximum, through: 1, by: -1).first { count in
                    zip(leftWords.suffix(count), rightWords.prefix(count)).allSatisfy {
                        wordKey($0) == wordKey($1) && !wordKey($0).isEmpty
                    }
                } ?? 0
                : 0
            let prefix = leftWords.dropLast(overlap).joined(separator: " ")
            return join(prefix, rightWords.joined(separator: " "))
        }

        let leftCharacters = Array(left)
        let rightCharacters = Array(right)
        let maximum = min(
            maximumOverlapCharacters, leftCharacters.count, rightCharacters.count
        )
        let overlap = maximum > 0
            ? stride(from: maximum, through: 1, by: -1).first { count in
                Array(leftCharacters.suffix(count)) == Array(rightCharacters.prefix(count))
            } ?? 0
            : 0
        return left + String(right.dropFirst(overlap))
    }

    private static func wordKey(_ word: String) -> String {
        word.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func join(_ left: String, _ right: String) -> String {
        guard !left.isEmpty else { return right }
        guard !right.isEmpty else { return left }
        if right.first.map({ ".,!?;:%)]}".contains($0) }) == true { return left + right }
        return "\(left) \(right)"
    }
}
