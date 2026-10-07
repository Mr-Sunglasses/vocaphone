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

    /// Whether the last stretch of the recording was decoded before Finish,
    /// during the pause at its end, rather than after it.
    var reusedEarlyDecode = false

    /// Milliseconds of trailing non-speech left out of the decode.
    var trimmedMilliseconds = 0

    static let empty = SherpaIncrementalResult(transcript: .empty, droppedAudibleChunk: false)

    /// Whether a whole-file re-decode is worth taking over this result.
    ///
    /// The re-decode exists to recover seconds the streaming pass lost, and it
    /// is only evidence of that if it came back with more. The same model that
    /// dropped a chunk in one pass drops one in the other — over a recording
    /// with a long pause in it, routinely — so taking the second pass on faith
    /// trades a hole for a bigger one, and the user watches a finished sentence
    /// lose its opening half.
    ///
    /// Measured after the sanitizer, as the user would read either one. A pass
    /// that fell into a repetition loop is the longest answer of all in raw
    /// characters — a phrase emitted until the window ran out — and once the
    /// loop is collapsed it is often the shorter one.
    func supersededBy(_ wholeFile: String) -> Bool {
        TranscriptSanitizer.clean(wholeFile).count > TranscriptSanitizer.clean(transcript.text).count
    }
}

/// Consumes captured PCM while the microphone is still running. The WAV file
/// remains authoritative, but Sherpa's expensive offline work is spread over
/// the recording instead of making the user wait for the whole file at finish.
///
/// Two things run on the way. Every twelve seconds the first ten are decoded
/// and let go, which is what bounds a long dictation's wait. And whenever the
/// speaker pauses, the audio not yet decoded is decoded *then*, ahead of
/// Finish: if nothing more is said before the recording ends, that answer is
/// the transcript's last stretch and Finish has nothing left to wait for. A
/// dictation is almost always under twelve seconds, so without the second one
/// the whole of it was decoded after Finish.
final class SherpaIncrementalSession: @unchecked Sendable {
    private let task: Task<SherpaIncrementalResult, Never>

    /// `decode` is handed one complete chunk at a time and must be safe to call
    /// off the main actor; the recognizer overload in the app target supplies
    /// the real one. `detector` is made on the consuming task, which owns it;
    /// nil, or a factory that returns nil, decodes exactly as before: nothing
    /// early and nothing trimmed.
    ///
    /// `onText` hears the words decoded so far each time they change — a chunk
    /// let go, or a pause decoded early — for the keyboard to show while the
    /// speaker is still talking. It is a preview: the transcript is whatever
    /// `finish` returns.
    init(
        chunks: AsyncStream<Data>,
        detector: (@Sendable () -> SpeechActivityDetecting?)? = nil,
        onText: (@Sendable (String) -> Void)? = nil,
        decode: @escaping @Sendable ([Float]) -> SherpaDecodeOutcome
    ) {
        task = Task.detached(priority: .userInitiated) {
            await Self.transcribe(chunks: chunks, detector: detector?(), onText: onText, decode: decode)
        }
    }

    func finish() async -> SherpaIncrementalResult { await task.value }

    func cancel() { task.cancel() }

    /// A decode of the audio not yet committed, made during a pause.
    private struct EarlyDecode {
        /// Where the decoded audio started and ended, in recording samples.
        let start: Int
        let end: Int
        /// The gain it was levelled with. A louder passage after it moves the
        /// gain, and audio levelled differently is not the audio decoded.
        let gain: Float
        let outcome: SherpaDecodeOutcome
    }

    private static func transcribe(
        chunks: AsyncStream<Data>,
        detector: SpeechActivityDetecting?,
        onText: (@Sendable (String) -> Void)? = nil,
        decode: @Sendable ([Float]) -> SherpaDecodeOutcome
    ) async -> SherpaIncrementalResult {
        var samples: [Float] = []
        samples.reserveCapacity(
            SherpaLongAudio.streamingWindowSeconds * SherpaLongAudio.sampleRate
        )
        // Where `samples` begins in the recording.
        var offset = 0
        var transcript = SherpaTranscript.empty
        var overlapsPrevious = false
        var droppedAudibleChunk = false
        // The gain a chunk is levelled with has to come from more than the chunk
        // itself: one gain per chunk moves the level at every boundary, and a
        // chunk that is all pause would be amplified into noise the model
        // transcribes as words. The level of everything captured so far is the
        // closest a streaming chunk gets to the single gain the whole-file path
        // applies — measured the same way, so a click is not the level.
        var level = SpeechAudioConditioning.RunningLevel()
        // The loudest frame of everything decoded so far, which is what a later
        // chunk's level is judged against. Read before this chunk contributes
        // to it, so a pause is compared with the speech around it and never
        // with itself.
        var loudestFrame = 0.0
        // How much of the front of the next chunk the previous split already
        // decoded. Everything a window can lose sits after it, so it is what
        // the emptiness of its answer is judged on.
        var retainedHead = 0
        // Speech the detector has heard, in recording samples.
        var regions: [SpeechRegion] = []
        var earlyDecode: EarlyDecode?
        var reported = ""

        /// Tells `onText` about a preview that changed, and nothing else.
        func report(_ preview: SherpaTranscript) {
            guard let onText else { return }
            let text = preview.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text != reported else { return }
            reported = text
            onText(text)
        }

        /// Skipped as silence, or decoded — levelled with `gain`.
        func decodeLevelled(_ chunk: [Float], gain: Float) -> SherpaDecodeOutcome? {
            // Silence is judged on the capture as it arrived. The levelling
            // below multiplies a quiet recording by as much as eight, and a
            // floor meant for microphone levels reads amplified room tone as
            // speech — which buys a decode, the two more the empty-chunk
            // recovery adds on top, and then the whole-file re-run the flag
            // asks the caller for. All to transcribe a pause.
            guard !SherpaLongAudio.isEffectivelySilent(chunk) else { return nil }
            return decode(SpeechAudioConditioning.condition(chunk, gain: gain))
        }

        func consume(_ chunk: [Float], outcome: SherpaDecodeOutcome?) {
            guard let outcome else { return }
            let chunkLevel = SherpaLongAudio.loudestFrame(chunk)
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
            loudestFrame = max(loudestFrame, chunkLevel)
            transcript = transcript.appending(decoded, deduplicateOverlap: overlapsPrevious)
        }

        /// The gain the level of everything captured so far calls for.
        func currentGain() -> Float { SpeechAudioConditioning.gain(forLevel: level.level) }

        /// Decodes what is not yet committed, up to just past the last word
        /// heard, while the speaker is quiet.
        func decodeEarly() {
            guard let lastEnd = regions.last?.end else { return }
            let end = min(lastEnd + SpeechActivity.tailPaddingSamples, offset + samples.count)
            guard end > offset, earlyDecode?.end != end || earlyDecode?.start != offset else { return }
            let gain = currentGain()
            let chunk = Array(samples[..<(end - offset)])
            // A pause with nothing decodable before it is not worth a result;
            // the finish path decides that for itself.
            guard let outcome = decodeLevelled(chunk, gain: gain) else { return }
            earlyDecode = EarlyDecode(start: offset, end: end, gain: gain, outcome: outcome)
            if case let .decoded(decoded) = outcome {
                report(transcript.appending(decoded, deduplicateOverlap: overlapsPrevious))
            }
        }

        func result(reusedEarlyDecode: Bool = false, trimmed: Int = 0) -> SherpaIncrementalResult {
            var result = SherpaIncrementalResult(
                transcript: SherpaTranscript(
                    text: transcript.text.trimmingCharacters(in: .whitespacesAndNewlines),
                    language: transcript.language
                ),
                droppedAudibleChunk: droppedAudibleChunk
            )
            result.reusedEarlyDecode = reusedEarlyDecode
            result.trimmedMilliseconds = trimmed * 1_000 / SherpaLongAudio.sampleRate
            return result
        }

        for await data in chunks {
            guard !Task.isCancelled else { return result() }
            let incoming = Self.floatSamples(in: data)
            level.append(incoming)
            samples.append(contentsOf: incoming)
            let closed = detector?.accept(incoming) ?? []
            regions += closed

            while let split = SherpaLongAudio.nextStreamingSplit(
                samples,
                speech: SpeechActivity.regions(regions, from: offset)
            ) {
                let chunk = Array(samples[..<split.endExclusive])
                consume(chunk, outcome: decodeLevelled(chunk, gain: currentGain()))
                samples.removeFirst(split.nextStart)
                offset += split.nextStart
                overlapsPrevious = split.nextStart < split.endExclusive
                retainedHead = split.endExclusive - split.nextStart
                earlyDecode = nil
                report(transcript)
            }
            if !closed.isEmpty { decodeEarly() }
        }

        guard !samples.isEmpty else { return result() }
        regions += detector?.finish() ?? []
        // The pause after the last word, and the tap on Finish, are not worth
        // a model's time, and are left out only where nothing in them could be
        // speech.
        let end = SpeechActivity.trimmedEnd(
            of: samples,
            regions: SpeechActivity.regions(regions, from: offset)
        ) ?? samples.count
        let tail = Array(samples[..<end])
        let gain = currentGain()
        // The same audio at the same gain, or it is decoded again: a result
        // for different model input is not this recording's result.
        if let early = earlyDecode, early.start == offset, early.end == offset + end,
           early.gain == gain
        {
            consume(tail, outcome: early.outcome)
            return result(reusedEarlyDecode: true, trimmed: samples.count - end)
        }
        consume(tail, outcome: decodeLevelled(tail, gain: gain))
        return result(trimmed: samples.count - end)
    }

    private static func floatSamples(in data: Data) -> [Float] {
        guard data.count >= MemoryLayout<Float>.stride else { return [] }
        return data.withUnsafeBytes { rawBuffer in
            let values = rawBuffer.bindMemory(to: Float.self)
            return Array(values)
        }
    }
}
