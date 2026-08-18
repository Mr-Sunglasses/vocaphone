import Foundation

/// Keeps offline encoders away from unbounded long-recording sequences. The
/// boundary search prefers a quiet 100 ms frame around ten seconds and retains
/// a short overlap when continuous speech cannot be split cleanly.
enum SherpaLongAudio {
    static let sampleRate = 16_000
    static let longAudioThresholdSeconds = 12
    static let targetChunkSeconds = 10
    static let maxChunkSeconds = 14
    static let overlapSamples = sampleRate / 2
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
            let useOverlap = silence == nil
            result.append(Chunk(start: start, endExclusive: end, overlapsPrevious: overlapsPrevious))
            start = useOverlap ? max(end - overlapSamples, start + 1) : end
            overlapsPrevious = useOverlap
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
        return StreamingSplit(
            endExclusive: end,
            nextStart: silence == nil ? end - overlapSamples : end
        )
    }

    private static func findSilenceBoundary(
        samples: [Float], idealEnd: Int, minEnd: Int, maxEnd: Int
    ) -> Int? {
        let first = max(idealEnd - silenceSearchSamples, minEnd)
            / silenceFrameSamples * silenceFrameSamples
        let last = min(idealEnd + silenceSearchSamples, maxEnd, samples.count - silenceFrameSamples)
            / silenceFrameSamples * silenceFrameSamples
        guard first <= last else { return nil }

        var peak = 0.0
        var lowest = Double.greatestFiniteMagnitude
        var quietStart = -1
        var frame = first
        while frame <= last {
            let value = rms(samples, start: frame, endExclusive: frame + silenceFrameSamples)
            peak = max(peak, value)
            if value < lowest {
                lowest = value
                quietStart = frame
            }
            frame += silenceFrameSamples
        }
        let threshold = max(minSilenceRMS, peak * silenceRMSRatio)
        guard quietStart >= 0, lowest <= threshold else { return nil }
        return min(max(quietStart + silenceFrameSamples / 2, minEnd), maxEnd)
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
    private static let maximumOverlapWords = 12

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
        let maximum = min(12, leftCharacters.count, rightCharacters.count)
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
