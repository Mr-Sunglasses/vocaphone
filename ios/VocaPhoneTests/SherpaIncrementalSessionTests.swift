import Foundation
import Testing

/// The incremental path decodes a long recording as chunks while the microphone
/// is still open, so a chunk that comes back with no tokens takes its seconds
/// out of the transcript without leaving a trace in the text. These cover the
/// two things that keep those seconds: the caller is told, and the model is not
/// handed audio quieter than the whole-file path would give it.
struct SherpaIncrementalSessionTests {

    private static let sampleRate = SherpaLongAudio.sampleRate

    /// Speech-shaped enough to clear the silence floor, at whatever level the
    /// microphone is being asked to imitate.
    private static func tone(seconds: Double, amplitude: Float) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { index in
            amplitude * sin(Float(index) * 0.08) * (0.4 + 0.6 * abs(sin(Float(index) * 0.0004)))
        }
    }

    private static func stream(_ samples: [Float]) -> AsyncStream<Data> {
        AsyncStream { continuation in
            var index = 0
            while index < samples.count {
                let end = min(index + 1_600, samples.count)
                let slice = Array(samples[index..<end])
                continuation.yield(slice.withUnsafeBufferPointer { Data(buffer: $0) })
                index = end
            }
            continuation.finish()
        }
    }

    /// Room between sentences: above the near-silence floor, as a real room is.
    private static func room(seconds: Double) -> [Float] {
        let count = Int(Double(sampleRate) * seconds)
        return (0..<count).map { $0 % 2 == 0 ? 0.008 : -0.008 }
    }

    /// What a transducer does: words for a chunk with speech in it, nothing for
    /// a chunk of room tone. Reads the levelled audio the session hands over,
    /// where speech has been brought to the 0.85 target and a pause has not.
    private static func healthyModel(_ chunk: [Float]) -> SherpaDecodeOutcome {
        let peak = chunk.reduce(Float(0)) { max($0, abs($1)) }
        return .decoded(SherpaTranscript(text: peak > 0.3 ? "spoken" : ""))
    }

    @Test func aHealthyModelNeverPaysForASecondPass() async {
        // Every shape an ordinary dictation takes. None of them may set the
        // flag: it costs the whole recording decoded again at finish, which is
        // the entire wait this path exists to remove, and the fast families pay
        // most of their finish time to it.
        let shapes: [(String, [Float])] = [
            ("one sentence", Self.tone(seconds: 5, amplitude: 0.4)),
            ("past a boundary", Self.tone(seconds: 22, amplitude: 0.4)),
            ("left running after the last word",
             Self.tone(seconds: 20, amplitude: 0.4) + Self.room(seconds: 10)),
            ("a long pause to think",
             Self.tone(seconds: 10, amplitude: 0.4) + Self.room(seconds: 12)
                + Self.tone(seconds: 10, amplitude: 0.4)),
            ("unbroken", Self.tone(seconds: 40, amplitude: 0.4)),
        ]

        for (name, samples) in shapes {
            let session = SherpaIncrementalSession(chunks: Self.stream(samples)) {
                Self.healthyModel($0)
            }
            let result = await session.finish()

            #expect(!result.droppedAudibleChunk, "\(name) asked for a second pass")
            #expect(result.transcript.text.hasPrefix("spoken"), "\(name) lost its words")
        }
    }

    @Test func aChunkThatDecodesToNothingIsReported() async {
        let decoded = OSAllocatedCounter()
        let session = SherpaIncrementalSession(
            chunks: Self.stream(Self.tone(seconds: 25, amplitude: 0.4))
        ) { _ in
            // Exactly the failure this exists for: the first long chunk comes
            // back empty and every later one succeeds, so the merged text reads
            // as a whole sentence that starts ten seconds in.
            decoded.increment() == 1 ? .decoded(SherpaTranscript(text: "")) : .decoded(SherpaTranscript(text: "later"))
        }
        let result = await session.finish()

        #expect(decoded.value > 1)
        #expect(result.transcript.text == "later")
        #expect(result.droppedAudibleChunk)
    }

    @Test func aCompleteRunReportsNothingDropped() async {
        let session = SherpaIncrementalSession(
            chunks: Self.stream(Self.tone(seconds: 25, amplitude: 0.4))
        ) { _ in .decoded(SherpaTranscript(text: "spoken")) }
        let result = await session.finish()

        #expect(!result.droppedAudibleChunk)
        #expect(result.transcript.text.hasPrefix("spoken"))
    }

    @Test func silenceIsNotMistakenForADroppedChunk() async {
        let session = SherpaIncrementalSession(
            chunks: Self.stream([Float](repeating: 0, count: Self.sampleRate * 25))
        ) { _ in .decoded(SherpaTranscript(text: "")) }
        let result = await session.finish()

        // Nothing was said, so nothing was lost, and a whole-file retry of the
        // same silence would only cost the user time.
        #expect(result.transcript.text.isEmpty)
        #expect(!result.droppedAudibleChunk)
    }

    @Test func quietChunksReachTheModelLevelled() async {
        let peaks = OSAllocatedPeaks()
        let session = SherpaIncrementalSession(
            chunks: Self.stream(Self.tone(seconds: 25, amplitude: 0.05))
        ) { samples in
            peaks.record(samples.reduce(Float(0)) { max($0, abs($1)) })
            return .decoded(SherpaTranscript(text: "spoken"))
        }
        _ = await session.finish()

        // A phone on a desk records far below what an int8 model was trained
        // on. The whole-file path has always levelled that; the streaming path
        // used to hand the model the raw 0.05.
        #expect(peaks.recorded.allSatisfy { $0 > 0.3 })
    }

    @Test func theGainComesFromTheRecordingAndNotFromTheChunk() async {
        // Loud speech, then a passage far quieter but still plainly speech.
        var samples = Self.tone(seconds: 13, amplitude: 0.5)
        samples += Self.tone(seconds: 16, amplitude: 0.03)
        let peaks = OSAllocatedPeaks()
        let session = SherpaIncrementalSession(chunks: Self.stream(samples)) { chunk in
            peaks.record(chunk.reduce(Float(0)) { max($0, abs($1)) })
            return .decoded(SherpaTranscript(text: "spoken"))
        }
        _ = await session.finish()

        // The quiet passage keeps its place under the loud one. Levelling it on
        // its own peak would have pushed it to the 0.85 target, which is how a
        // pause becomes noise the model transcribes as words.
        #expect(peaks.recorded.count > 1)
        #expect(peaks.recorded.last! > 0.03)
        #expect(peaks.recorded.last! < 0.1)
    }

    /// The bug a chunk-length bar hid. A window can be well under the suspect
    /// length and still be the last two seconds of the recording: the tail after
    /// a split is never smaller than the streaming window minus what it
    /// retained. Asking whether the *chunk* was long enough let a closing
    /// sentence vanish with nothing downstream able to tell.
    @Test func aShortTailCarryingNewSpeechIsADroppedChunk() async {
        let sizes = RecordedSizes()
        let session = SherpaIncrementalSession(
            chunks: Self.stream(Self.tone(seconds: 22, amplitude: 0.4))
        ) { samples in
            sizes.record(samples.count)
            return samples.count < 6 * Self.sampleRate
                ? .decoded(SherpaTranscript(text: ""))
                : .decoded(SherpaTranscript(text: "spoken"))
        }
        let result = await session.finish()

        #expect(sizes.recorded.last! < 6 * Self.sampleRate)
        #expect(result.droppedAudibleChunk)
    }

    /// The tail that stays ignorable, stated as the rule the session applies.
    /// A recording ending just after a boundary leaves the retained overlap
    /// behind and nothing else, and an empty answer for audio the previous
    /// window already decoded is not a loss — calling it one re-runs the whole
    /// recording through the model at finish, which is the exact wait the
    /// streaming path exists to remove.
    @Test func aTailThatIsOnlyRetainedOverlapIsNotADroppedChunk() {
        let overlapOnly = [Float](repeating: 0.4, count: SherpaLongAudio.overlapSamples)

        #expect(!SherpaLongAudio.carriesRecoverableSpeech(
            newRegion: overlapOnly,
            inheritsAudio: true,
            loudestFrame: SherpaLongAudio.loudestFrame(overlapOnly),
            loudestFrameSoFar: 0.4
        ))
    }

    /// And the same rule the other way: new audio past the overlap, at the level
    /// of the speech around it, is a loss whatever the window's total length.
    @Test func newAudioPastTheOverlapIsRecoverable() {
        let region = [Float](repeating: 0.4, count: 2 * SherpaLongAudio.sampleRate)

        #expect(SherpaLongAudio.carriesRecoverableSpeech(
            newRegion: region,
            inheritsAudio: true,
            loudestFrame: SherpaLongAudio.loudestFrame(region),
            loudestFrameSoFar: 0.4
        ))
    }

    /// Room tone past the overlap is still not a loss: the bar is the level of
    /// the speech already heard, not merely the presence of samples.
    @Test func roomTonePastTheOverlapIsNotRecoverable() {
        let region = [Float](repeating: 0.01, count: 2 * SherpaLongAudio.sampleRate)

        #expect(!SherpaLongAudio.carriesRecoverableSpeech(
            newRegion: region,
            inheritsAudio: true,
            loudestFrame: SherpaLongAudio.loudestFrame(region),
            loudestFrameSoFar: 0.4
        ))
    }

    /// The length bar is for telling new audio apart from retained overlap, so
    /// it cannot apply where nothing was retained. A one-word dictation is short
    /// because that is all there was to say, and it was never decoded before.
    @Test func aSoleWindowShorterThanTheOverlapIsStillRecoverable() {
        let oneWord = [Float](repeating: 0.4, count: SherpaLongAudio.sampleRate / 4)

        #expect(SherpaLongAudio.carriesRecoverableSpeech(
            newRegion: oneWord,
            inheritsAudio: false,
            loudestFrame: SherpaLongAudio.loudestFrame(oneWord),
            loudestFrameSoFar: 0
        ))
        // The same audio arriving as a tail behind a decoded window is not.
        #expect(!SherpaLongAudio.carriesRecoverableSpeech(
            newRegion: oneWord,
            inheritsAudio: true,
            loudestFrame: SherpaLongAudio.loudestFrame(oneWord),
            loudestFrameSoFar: 0.4
        ))
    }

    /// A native failure is not a model that heard nothing, but the seconds are
    /// missing either way, so the whole-file pass still has to run.
    @Test func aNativeFailureIsCountedAsALossRatherThanAnEmptyAnswer() async {
        let session = SherpaIncrementalSession(
            chunks: Self.stream(Self.tone(seconds: 22, amplitude: 0.4))
        ) { _ in .failed(.streamUnavailable) }

        let result = await session.finish()

        #expect(result.transcript.text.isEmpty)
        #expect(result.droppedAudibleChunk)
    }

    @Test func aPauseInTheMiddleOfARecordingIsNotADroppedChunk() async {
        // Room tone loud enough to clear the near-silence floor, which is what
        // a real room sounds like between two sentences. It is decoded, because
        // skipping it would risk skipping quiet speech — but it decoding to
        // nothing is the right answer, not a loss.
        var samples = Self.tone(seconds: 13, amplitude: 0.4)
        samples += (0..<(Self.sampleRate * 16)).map { $0 % 2 == 0 ? 0.02 : -0.02 }
        let decoded = RecordedSizes()
        let session = SherpaIncrementalSession(chunks: Self.stream(samples)) { chunk in
            decoded.record(chunk.count)
            return decoded.recorded.count > 2
                ? .decoded(SherpaTranscript(text: ""))
                : .decoded(SherpaTranscript(text: "spoken"))
        }
        let result = await session.finish()

        #expect(decoded.recorded.count == 3)
        #expect(!result.droppedAudibleChunk)
    }

    @Test func theWholeFileRetryIsOnlyTakenWhenItRecoveredSomething() {
        let streamed = SherpaIncrementalResult(
            transcript: SherpaTranscript(text: "the opening half and the rest of it"),
            droppedAudibleChunk: true
        )

        #expect(streamed.supersededBy("the opening half and the rest of it, and more"))
        // The retry lost the opening half, which is the failure it was asked to
        // fix. Shipping it would cut a sentence the user watched being said.
        #expect(!streamed.supersededBy("the rest of it"))
        #expect(!streamed.supersededBy(""))
    }

    @Test func trailingRoomToneIsNeitherDecodedNorCountedAsALoss() async {
        // Quiet speech, so the levelling gain reaches its eight-times ceiling —
        // enough to lift room tone over a threshold meant for capture levels.
        var samples = Self.tone(seconds: 13, amplitude: 0.05)
        samples += (0..<(Self.sampleRate * 16)).map { $0 % 2 == 0 ? 0.002 : -0.002 }
        let decoded = RecordedSizes()
        let session = SherpaIncrementalSession(chunks: Self.stream(samples)) { chunk in
            decoded.record(chunk.count)
            return decoded.recorded.count > 2
                ? .decoded(SherpaTranscript(text: ""))
                : .decoded(SherpaTranscript(text: "spoken"))
        }
        let result = await session.finish()

        // Nothing was said over those ten seconds, so there was nothing to
        // lose, and asking the model anyway costs a decode plus the two the
        // empty-chunk recovery would add on top.
        #expect(decoded.recorded.count == 2)
        #expect(!result.droppedAudibleChunk)
    }
}

/// The decode closure runs off the main actor, so the counters it touches have
/// to be safe to share.
private final class OSAllocatedCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    @discardableResult
    func increment() -> Int {
        lock.lock()
        defer { lock.unlock() }
        count += 1
        return count
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class OSAllocatedPeaks: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Float] = []

    func record(_ peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        values.append(peak)
    }

    var recorded: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

private final class RecordedSizes: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func record(_ size: Int) {
        lock.lock()
        defer { lock.unlock() }
        values.append(size)
    }

    var recorded: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}
