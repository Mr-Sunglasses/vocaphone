import Foundation
import Testing

/// A detector that reports the regions it was given, each once the audio fed
/// to it has reached the point a real one would close it: its end plus the
/// pause it waits for.
final class ScriptedSpeechDetector: SpeechActivityDetecting {
    private var pending: [SpeechRegion]
    private var fed = 0

    init(_ regions: [SpeechRegion]) {
        pending = regions
    }

    func accept(_ samples: [Float]) -> [SpeechRegion] {
        fed += samples.count
        let pause = Int(SpeechActivity.pauseSeconds * Float(SpeechActivity.sampleRate))
        let closed = pending.filter { $0.end + pause <= fed }
        pending.removeAll { $0.end + pause <= fed }
        return closed
    }

    func finish() -> [SpeechRegion] {
        defer { pending = [] }
        return pending
    }
}

extension SileroSpeechDetector {
    /// The checked-in model, which is the one the app bundles. The test bundle
    /// does not carry a copy.
    static var repositoryModel: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VocaPhoneApp/Models/silero_vad.onnx")
    }
}

struct SpeechActivityTests {
    private static let rate = SpeechActivity.sampleRate

    static func tone(seconds: Double, amplitude: Float = 0.4) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { amplitude * sin(Float($0) * 0.08) }
    }

    static func room(seconds: Double, level: Float = 0.002) -> [Float] {
        (0..<Int(Double(rate) * seconds)).map { $0 % 2 == 0 ? level : -level }
    }

    static func stream(_ samples: [Float]) -> AsyncStream<Data> {
        AsyncStream { continuation in
            var index = 0
            while index < samples.count {
                let end = min(index + 1_600, samples.count)
                continuation.yield(Array(samples[index..<end]).withUnsafeBufferPointer { Data(buffer: $0) })
                index = end
            }
            continuation.finish()
        }
    }

    // MARK: - Trimming

    @Test func theTailAfterTheLastWordIsCutWithRoomToSpare() {
        let recording = Self.tone(seconds: 3) + Self.room(seconds: 2)
        let end = SpeechActivity.trimmedEnd(
            of: recording, regions: [SpeechRegion(start: 0, end: 3 * Self.rate)]
        )
        #expect(end == 3 * Self.rate + SpeechActivity.tailPaddingSamples)
    }

    /// A detector that heard nothing is not trusted to throw anything away.
    @Test func noSpeechHeardMeansNothingIsCut() {
        let recording = Self.tone(seconds: 3) + Self.room(seconds: 2)
        #expect(SpeechActivity.trimmedEnd(of: recording, regions: []) == nil)
    }

    /// The last word, too quiet or too short for the detector, is still loud
    /// next to the speech before it, and it stays.
    @Test func aLastWordTheDetectorMissedIsKept() {
        let recording = Self.tone(seconds: 3) + Self.room(seconds: 1)
            + Self.tone(seconds: 0.3, amplitude: 0.2) + Self.room(seconds: 0.5)
        #expect(SpeechActivity.trimmedEnd(
            of: recording, regions: [SpeechRegion(start: 0, end: 3 * Self.rate)]
        ) == nil)
    }

    /// A final word far quieter than the speech before it, after a pause,
    /// that the detector did not hear. Against the speech it is nothing;
    /// against the room it is plainly a word.
    @Test func aQuietFinalWordTheDetectorMissedIsKept() {
        let recording = Self.tone(seconds: 3) + Self.room(seconds: 1)
            + Self.tone(seconds: 0.4, amplitude: 0.012) + Self.room(seconds: 0.6)
        #expect(SpeechActivity.trimmedEnd(
            of: recording, regions: [SpeechRegion(start: 0, end: 3 * Self.rate)]
        ) == nil)
    }

    /// The tap on Finish is shorter than any word, and does not stop the pause
    /// before it from being trimmed.
    @Test func aTapAtTheEndStillTrims() {
        var recording = Self.tone(seconds: 3) + Self.room(seconds: 1.5)
        for index in (recording.count - 800)..<recording.count { recording[index] += 0.6 }
        #expect(SpeechActivity.trimmedEnd(
            of: recording, regions: [SpeechRegion(start: 0, end: 3 * Self.rate)]
        ) == 3 * Self.rate + SpeechActivity.tailPaddingSamples)
    }

    /// Through the session: the quiet word reaches the model.
    @Test func aQuietFinalWordReachesTheSherpaModel() async {
        let samples = Self.tone(seconds: 3) + Self.room(seconds: 1)
            + Self.tone(seconds: 0.4, amplitude: 0.012) + Self.room(seconds: 0.6)
        let decoded = Sizes()
        let session = SherpaIncrementalSession(
            chunks: Self.stream(samples),
            detector: { ScriptedSpeechDetector([SpeechRegion(start: 0, end: 3 * Self.rate)]) }
        ) { chunk in
            decoded.record(chunk.count)
            return .decoded(SherpaTranscript(text: "spoken"))
        }
        let result = await session.finish()
        #expect(!result.reusedEarlyDecode)
        #expect(decoded.values.last == samples.count)
    }

    @Test func aTailTooShortToMatterIsLeftAlone() {
        let recording = Self.tone(seconds: 3) + Self.room(seconds: 0.45)
        #expect(SpeechActivity.trimmedEnd(
            of: recording, regions: [SpeechRegion(start: 0, end: 3 * Self.rate)]
        ) == nil)
    }

    @Test func regionsAreMovedIntoABufferThatStartsLater() {
        let moved = SpeechActivity.regions(
            [SpeechRegion(start: 0, end: 100), SpeechRegion(start: 150, end: 400)],
            from: 200
        )
        #expect(moved == [SpeechRegion(start: 0, end: 200)])
    }

    // MARK: - Levelling

    @Test func theRunningLevelIsTheWholeRecordingLevel() {
        var generator = SystemRandomNumberGenerator()
        for length in [0, 100, 320, 3_200, 48_017] {
            let samples = (0..<length).map { _ in Float.random(in: -0.5...0.5, using: &generator) }
            var running = SpeechAudioConditioning.RunningLevel()
            for start in stride(from: 0, to: samples.count, by: 1_600) {
                running.append(Array(samples[start..<min(samples.count, start + 1_600)]))
            }
            #expect(running.level == SpeechAudioConditioning.speechLevel(samples))
        }
    }

    /// The finger that started the dictation used to set the streaming gain,
    /// and quiet speech after it was handed to the model as it arrived.
    @Test func aClickDoesNotStopQuietSpeechBeingLevelledWhileStreaming() async {
        var samples = Self.tone(seconds: 0.02, amplitude: 0.9)
        samples += Self.tone(seconds: 24, amplitude: 0.05)
        let peaks = Peaks()
        let session = SherpaIncrementalSession(chunks: Self.stream(samples)) { chunk in
            peaks.record(chunk.reduce(Float(0)) { max($0, abs($1)) })
            return .decoded(SherpaTranscript(text: "spoken"))
        }
        _ = await session.finish()
        #expect(peaks.values.count >= 2)
        #expect(peaks.values.allSatisfy { $0 > 0.3 })
    }

    @Test func levellingReportsTheGainItApplied() {
        let quiet = Self.tone(seconds: 2, amplitude: 0.05)
        let levelled = SpeechAudioConditioning.levelled(quiet)
        #expect(levelled.gain > 1)
        #expect(levelled.samples == SpeechAudioConditioning.condition(quiet))
        #expect(SpeechAudioConditioning.levelled(Self.tone(seconds: 2, amplitude: 0.9)).gain == 1)
    }

    // MARK: - Sherpa: decoding during the pause before Finish

    @Test func aDictationEndingInAPauseIsDecodedBeforeFinish() async {
        let samples = Self.tone(seconds: 5) + Self.room(seconds: 2)
        let decodes = Sizes()
        let session = SherpaIncrementalSession(
            chunks: Self.stream(samples),
            detector: { ScriptedSpeechDetector([SpeechRegion(start: 0, end: 5 * Self.rate)]) }
        ) { chunk in
            decodes.record(chunk.count)
            return .decoded(SherpaTranscript(text: "spoken"))
        }
        let result = await session.finish()

        #expect(result.transcript.text == "spoken")
        #expect(result.reusedEarlyDecode)
        // One decode, of the speech and its padding, and none after it.
        #expect(decodes.values == [5 * Self.rate + SpeechActivity.tailPaddingSamples])
        #expect(result.trimmedMilliseconds > 1_000)
        #expect(!result.droppedAudibleChunk)
    }

    @Test func speechAfterThePauseIsDecodedAtFinish() async {
        let samples = Self.tone(seconds: 3) + Self.room(seconds: 1) + Self.tone(seconds: 2)
        let decodes = Sizes()
        let session = SherpaIncrementalSession(
            chunks: Self.stream(samples),
            detector: {
                ScriptedSpeechDetector([
                    SpeechRegion(start: 0, end: 3 * Self.rate),
                    SpeechRegion(start: 4 * Self.rate, end: 6 * Self.rate),
                ])
            }
        ) { chunk in
            decodes.record(chunk.count)
            return .decoded(SherpaTranscript(text: "words\(decodes.values.count)"))
        }
        let result = await session.finish()

        #expect(!result.reusedEarlyDecode)
        // The early decode, then the whole recording at Finish, which is what
        // the transcript is.
        #expect(decodes.values.count == 2)
        #expect(decodes.values.last == samples.count)
        #expect(result.transcript.text == "words2")
    }

    /// Without a detector the session decodes exactly as it always has.
    @Test func noDetectorMeansNoEarlyDecodeAndNoTrim() async {
        let samples = Self.tone(seconds: 5) + Self.room(seconds: 2)
        let decodes = Sizes()
        let session = SherpaIncrementalSession(chunks: Self.stream(samples)) { chunk in
            decodes.record(chunk.count)
            return .decoded(SherpaTranscript(text: "spoken"))
        }
        let result = await session.finish()
        #expect(decodes.values == [samples.count])
        #expect(!result.reusedEarlyDecode)
        #expect(result.trimmedMilliseconds == 0)
    }

    // MARK: - Whisper session

    @Test func whisperDecodesEarlyAndHandsBackTheSameAudio() async {
        let samples = Self.tone(seconds: 4) + Self.room(seconds: 2)
        let prefixes = Sizes()
        let session = WhisperIncrementalSession(
            chunks: Self.stream(samples),
            detector: { ScriptedSpeechDetector([SpeechRegion(start: 0, end: 4 * Self.rate)]) }
        ) { prefix in
            prefixes.record(prefix.count)
        }
        let audio = await session.finish()

        let end = 4 * Self.rate + SpeechActivity.tailPaddingSamples
        #expect(prefixes.values == [end])
        #expect(audio.samples.count == end)
        #expect(audio.samples == Array(samples[..<end]))
        #expect(audio.trimmedSamples == samples.count - end)
    }

    /// An early decode of audio that is no longer the recording's end is of no
    /// use to Finish, and is stopped rather than waited for.
    @Test func anEarlyDecodeOvertakenBySpeechIsCancelled() async {
        let samples = Self.tone(seconds: 3) + Self.room(seconds: 1) + Self.tone(seconds: 3)
        let cancelled = Flag()
        let session = WhisperIncrementalSession(
            chunks: Self.stream(samples),
            detector: { ScriptedSpeechDetector([SpeechRegion(start: 0, end: 3 * Self.rate)]) }
        ) { _ in
            // Stands in for a decode far slower than the rest of the capture.
            try? await Task.sleep(for: .seconds(30))
            if Task.isCancelled { cancelled.set() }
        }
        let started = ContinuousClock.now
        let audio = await session.finish()

        #expect(cancelled.value)
        #expect(ContinuousClock.now - started < .seconds(10))
        // Speech ran to the end, so nothing is trimmed.
        #expect(audio.samples.count == samples.count)
    }

    @Test func aWhisperDictationWithoutADetectorIsKeptWhole() async {
        let samples = Self.tone(seconds: 2) + Self.room(seconds: 2)
        let session = WhisperIncrementalSession(chunks: Self.stream(samples), detector: { nil }) { _ in
            Issue.record("nothing to decode early without a detector")
        }
        let audio = await session.finish()
        #expect(audio.samples == samples)
        #expect(audio.trimmedSamples == 0)
    }

    // MARK: - The real detector

    @Test func theSileroModelLoadsAndHearsNoSpeechInRoomTone() throws {
        let detector = try #require(SileroSpeechDetector(model: SileroSpeechDetector.repositoryModel))
        var regions: [SpeechRegion] = []
        let room = Self.room(seconds: 3)
        for start in stride(from: 0, to: room.count, by: 1_600) {
            regions += detector.accept(Array(room[start..<min(room.count, start + 1_600)]))
        }
        regions += detector.finish()
        #expect(regions.isEmpty)
    }

    /// sherpa-onnx ends the process over a model it cannot open.
    @Test func aMissingModelIsNoDetectorRatherThanACrash() {
        #expect(SileroSpeechDetector(model: URL(fileURLWithPath: "/nonexistent/silero_vad.onnx")) == nil)
        #expect(SileroSpeechDetector(model: nil) == nil)
    }

    // MARK: - Threads

    @Test func sherpaGetsOneWorkerPerPerformanceCore() {
        // An iPhone: two performance cores beside four efficiency cores.
        #expect(SherpaThreads.count(performanceCores: 2, processorCount: 6) == 2)
        #expect(SherpaThreads.count(performanceCores: 10, processorCount: 14) == 4)
        #expect(SherpaThreads.count(performanceCores: 1, processorCount: 4) == 2)
        // A system that will not say keeps the previous rule.
        #expect(SherpaThreads.count(performanceCores: nil, processorCount: 6) == 4)
    }
}

private final class Sizes: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Int] = []

    func record(_ size: Int) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(size)
    }

    var values: [Int] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class Peaks: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Float] = []

    func record(_ peak: Float) {
        lock.lock()
        defer { lock.unlock() }
        recorded.append(peak)
    }

    var values: [Float] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var raised = false

    func set() {
        lock.lock()
        defer { lock.unlock() }
        raised = true
    }

    var value: Bool {
        lock.lock()
        defer { lock.unlock() }
        return raised
    }
}
