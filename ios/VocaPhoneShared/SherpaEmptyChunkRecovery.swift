import Foundation

/// Recovers a window that decoded to nothing but demonstrably carried speech.
///
/// Some attention-based models occasionally return no tokens for a waveform
/// even though shorter speech from the same recording is recognized. This lives
/// in the shared target rather than beside the recognizer so the ladder can be
/// exercised without the native engine, exactly as Android's is.
///
/// Every rung re-asks the model. That is only ever worth a decode when the model
/// answered, so a native failure leaves the ladder at once and is handed back
/// for the caller to report as an engine failure — retrying a recognizer whose
/// stream would not open produces the same non-answer at the same price.
enum SherpaEmptyChunkRecovery {

    /// - Parameters:
    ///   - deduplicateOverlap: false when the caller is translating. The two
    ///     halves overlap so the word crossing the centre survives, and matching
    ///     the repeat back out only works when the same audio returns the same
    ///     words — which is exactly what a translator does not promise.
    ///   - recoverAudibleShortInput: true when an empty answer here cannot be
    ///     the ordinary short trailing overlap. See `SherpaRecognizer.transcribe`
    ///     for how that is decided.
    static func decode(
        samples: [Float],
        decodeOnce: ([Float]) -> SherpaDecodeOutcome,
        deduplicateOverlap: Bool,
        recoverAudibleShortInput: Bool = false
    ) -> SherpaDecodeOutcome {
        // Room tone is the ordinary reason for an empty answer, and the cheapest
        // thing to rule out before spending more decodes: the scan costs a pass
        // over the samples, a retry costs inference.
        guard !SherpaLongAudio.isEffectivelySilent(samples) else { return .empty }

        let attempt = decodeOnce(samples)
        guard case let .decoded(raw) = attempt else { return attempt }
        let first = trimmed(raw)
        guard first.text.isEmpty else { return .decoded(first) }

        // Length is what the split recovers from, so a window not long enough to
        // have been dropped for its length has nothing there to recover — unless
        // the caller has already established that this window is new speech.
        let short = samples.count <= SherpaLongAudio.minimumSuspectChunkSamples
        guard recoverAudibleShortInput || !short else { return .decoded(first) }

        // The two extra rungs are for short speech and stay there. A ten-second
        // window is already the length the split recovers from, and padding it
        // by half a second either side buys nothing for the cost of a whole
        // further decode — so a long window keeps the established ladder and its
        // predictable latency however little has been decoded before it.
        if short {
            // A fresh offline stream can recover a nondeterministic no-token
            // answer.
            switch decodeOnce(samples) {
            case let .failed(failure): return .failed(failure)
            case let .decoded(repeated) where !trimmed(repeated).text.isEmpty:
                return .decoded(trimmed(repeated))
            case .decoded: break
            }
            // Very short speech can begin or end too close to the encoder
            // context. Half a second either side is enough to move it inside,
            // and is bounded so a recording cannot grow its own decode cost.
            let padding = [Float](repeating: 0, count: SherpaLongAudio.sampleRate / 2)
            switch decodeOnce(padding + samples + padding) {
            case let .failed(failure): return .failed(failure)
            case let .decoded(padded) where !trimmed(padded).text.isEmpty:
                return .decoded(trimmed(padded))
            case .decoded: break
            }
        }

        // Retain context on both sides of the recovery boundary. A plain
        // midpoint split could rescue an empty window while still deleting the
        // word crossing its exact centre. One split and no more: a half-length
        // window that is still empty is not being lost to its length, and
        // subdividing again multiplies the decodes for nothing.
        //
        // Half the boundary overlap on each side, so the halves share exactly
        // the interval a chunk boundary retains and the merger is never asked
        // to match more repetition than the audio can account for. Clamped so a
        // very short recording does not hand both halves the whole waveform.
        let midpoint = samples.count / 2
        let overlap = min(SherpaLongAudio.overlapSamples / 2, midpoint / 2)
        let leftOutcome = decodeOnce(Array(samples[..<min(samples.count, midpoint + overlap)]))
        guard case let .decoded(left) = leftOutcome else { return leftOutcome }
        let rightOutcome = decodeOnce(Array(samples[max(0, midpoint - overlap)...]))
        guard case let .decoded(right) = rightOutcome else { return rightOutcome }
        return .decoded(left.appending(right, deduplicateOverlap: deduplicateOverlap))
    }

    private static func trimmed(_ transcript: SherpaTranscript) -> SherpaTranscript {
        SherpaTranscript(
            text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
            language: transcript.language
        )
    }
}
