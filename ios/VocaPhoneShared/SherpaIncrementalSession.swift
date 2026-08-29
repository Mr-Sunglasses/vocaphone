import Foundation

/// What an incremental session decoded, and whether any of the recording is
/// missing from it.
struct SherpaIncrementalResult: Sendable, Equatable {
    let transcript: SherpaTranscript

    /// True when a chunk that carried audio decoded to nothing.
    ///
    /// Those seconds are then simply absent, and nothing downstream can tell:
    /// the merge joins the chunks either side into text that reads as a whole
    /// sentence which happens to begin ten seconds into the recording. The
    /// attention families drop a long chunk often enough for this to be the
    /// difference between a transcript and a plausible-looking lie, so the
    /// caller re-decodes the file rather than shipping the hole.
    let droppedAudibleChunk: Bool

    static let empty = SherpaIncrementalResult(transcript: .empty, droppedAudibleChunk: false)

    /// Whether a whole-file re-decode is worth taking over this result.
    ///
    /// The re-decode exists to recover seconds the streaming pass lost, and it
    /// is only evidence of that if it came back with more. The same model that
    /// dropped a chunk in one pass drops one in the other — over a recording
    /// with a long pause in it, routinely — so taking the second pass on faith
    /// trades a hole for a bigger one, and the user watches a finished sentence
    /// lose its opening half.
    func supersededBy(_ wholeFile: String) -> Bool {
        wholeFile.count > transcript.text.count
    }
}

/// Consumes captured PCM while the microphone is still running. The WAV file
/// remains authoritative, but Sherpa's expensive offline work is spread over
/// the recording instead of making the user wait for the whole file at finish.
final class SherpaIncrementalSession: @unchecked Sendable {
    private let task: Task<SherpaIncrementalResult, Never>

    /// `decode` is handed one complete chunk at a time and must be safe to call
    /// off the main actor; the recognizer overload in the app target supplies
    /// the real one.
    init(
        chunks: AsyncStream<Data>,
        decode: @escaping @Sendable ([Float]) -> SherpaDecodeOutcome
    ) {
        task = Task.detached(priority: .userInitiated) {
            await Self.transcribe(chunks: chunks, decode: decode)
        }
    }

    func finish() async -> SherpaIncrementalResult { await task.value }

    func cancel() { task.cancel() }

    private static func transcribe(
        chunks: AsyncStream<Data>,
        decode: @Sendable ([Float]) -> SherpaDecodeOutcome
    ) async -> SherpaIncrementalResult {
        var samples: [Float] = []
        samples.reserveCapacity(
            SherpaLongAudio.streamingWindowSeconds * SherpaLongAudio.sampleRate
        )
        var transcript = SherpaTranscript.empty
        var overlapsPrevious = false
        var droppedAudibleChunk = false
        // The gain a chunk is levelled with has to come from more than the chunk
        // itself: one gain per chunk moves the level at every boundary, and a
        // chunk that is all pause would be amplified into noise the model
        // transcribes as words. The peak over everything captured so far is the
        // closest a streaming chunk gets to the single gain the whole-file path
        // applies, and it only ever grows, so the gain only ever settles.
        var peak: Float = 0
        // The loudest frame of everything decoded so far, which is what a later
        // chunk's level is judged against. Read before this chunk contributes
        // to it, so a pause is compared with the speech around it and never
        // with itself.
        var loudestFrame = 0.0
        // How much of the front of the next chunk the previous split already
        // decoded. Everything a window can lose sits after it, so it is what
        // the emptiness of its answer is judged on.
        var retainedHead = 0

        func consume(_ chunk: [Float]) {
            // Silence is judged on the capture as it arrived. The levelling
            // below multiplies a quiet recording by as much as eight, and a
            // floor meant for microphone levels reads amplified room tone as
            // speech — which buys a decode, the two more the empty-chunk
            // recovery adds on top, and then the whole-file re-run the flag
            // asks the caller for. All to transcribe a pause.
            let level = SherpaLongAudio.loudestFrame(chunk)
            guard !SherpaLongAudio.isEffectivelySilent(loudestFrame: level) else { return }
            let levelled = SpeechAudioConditioning.condition(chunk, peak: peak)
            let outcome = decode(levelled)
            // The engine failing to answer is not the model answering nothing.
            // Either way the seconds are missing from the transcript, so the
            // whole-file pass has to run — but it is recorded as a loss without
            // pretending the audio was examined and found empty.
            guard case let .decoded(decoded) = outcome else {
                droppedAudibleChunk = true
                return
            }
            // Judged on what this window did not inherit from the one before
            // it. A window that is mostly retained overlap can be six seconds
            // long and carry half a second of new speech, and asking whether
            // the *chunk* was long enough is what let that half second vanish
            // without the file ever being re-read. Below the bar an empty
            // answer is routine — the retained overlap itself, a fragment of a
            // word, the room tone while someone pauses to think — and treating
            // it as a loss spends a second pass to find out it was right.
            let newRegion = Array(chunk[min(retainedHead, chunk.count)...])
            if decoded.text.isEmpty,
               SherpaLongAudio.carriesRecoverableSpeech(
                   newRegion: newRegion,
                   inheritsAudio: retainedHead > 0,
                   loudestFrame: SherpaLongAudio.loudestFrame(newRegion),
                   loudestFrameSoFar: loudestFrame
               )
            {
                droppedAudibleChunk = true
            }
            loudestFrame = max(loudestFrame, level)
            transcript = transcript.appending(decoded, deduplicateOverlap: overlapsPrevious)
        }

        func result() -> SherpaIncrementalResult {
            SherpaIncrementalResult(
                transcript: SherpaTranscript(
                    text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    language: transcript.language
                ),
                droppedAudibleChunk: droppedAudibleChunk
            )
        }

        for await data in chunks {
            guard !Task.isCancelled else { return result() }
            let incoming = Self.floatSamples(in: data)
            peak = incoming.reduce(peak) { max($0, abs($1)) }
            samples.append(contentsOf: incoming)

            while let split = SherpaLongAudio.nextStreamingSplit(samples) {
                consume(Array(samples[..<split.endExclusive]))
                samples.removeFirst(split.nextStart)
                overlapsPrevious = split.nextStart < split.endExclusive
                retainedHead = split.endExclusive - split.nextStart
            }
        }

        if !samples.isEmpty { consume(samples) }
        return result()
    }

    private static func floatSamples(in data: Data) -> [Float] {
        guard data.count >= MemoryLayout<Float>.stride else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            return Array(values)
        }
    }
}
