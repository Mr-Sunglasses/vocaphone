import AVFAudio
import Foundation
import Testing

/// The keyboard's gateway path: what the app shares with it, the audio it
/// writes and streams, and the session rules that keep the app out of its way.
/// The gateway calls are the app's own (`GatewayClient`, `StreamingAudioBridge`)
/// and tested there; the capture needs WebKit in a keyboard and is
/// device-tested.
@Suite(.serialized)
struct KeyboardDictationTests {
    // MARK: Session record

    @Test func keyboardRecordingGoesStraightFromIdleToRecording() throws {
        var record = SessionRecord()
        record.capturedInKeyboard = true
        try record.transition(to: .recording)
        try record.transition(to: .finalizing)
        try record.transition(to: .uploading)
        try record.transition(to: .readyToInsert)
        #expect(record.state == .readyToInsert)
    }

    @Test func olderRecordsDecodeWithoutTheKeyboardFlag() throws {
        let record = SessionRecord()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(record)) as! [String: Any]
        json.removeValue(forKey: "capturedInKeyboard")
        let decoded = try JSONDecoder().decode(
            SessionRecord.self, from: JSONSerialization.data(withJSONObject: json)
        )
        #expect(decoded.capturedInKeyboard == nil)
    }

    @MainActor
    @Test func keyboardRecordingNeverShowsTheSwipeBackScreen() {
        var record = SessionRecord(state: .recording)
        record.startedInContainingApp = false
        record.processingLocation = .gateway
        #expect(KeyboardHandoffPresentation.make(record) != nil)
        record.capturedInKeyboard = true
        #expect(KeyboardHandoffPresentation.make(record) == nil)
    }

    // MARK: Failure and liveness

    /// Once the audio is at the gateway the record says `transcribing`, and an
    /// upload failure from there would be refused, leaving it stuck.
    @MainActor
    @Test func everyFailureIsOneTheRecordCanTake() throws {
        let failures: [SessionState] = [
            .uploadFailedRecoverable, .serverUnavailable, .transcriptionFailedPermanent,
        ]
        for current in [SessionState.finalizing, .uploading, .transcribing] {
            for wanted in failures {
                var record = SessionRecord()
                record.capturedInKeyboard = true
                try record.transition(to: .recording)
                try record.transition(to: .finalizing)
                if current != .finalizing { try record.transition(to: .uploading) }
                if current == .transcribing { try record.transition(to: .transcribing) }
                try record.transition(to: KeyboardDictation.failureState(wanted, from: current))
                #expect(record.state.isTerminal || record.canRetry)
            }
        }
    }

    @Test func aSessionWithoutAHeartbeatIsNotAlive() {
        let id = UUID()
        #expect(!KeyboardDictation.isAlive(id))
        KeyboardDictation.forgetHeartbeat(id)
        #expect(!KeyboardDictation.isAlive(id))
    }

    @MainActor
    @Test func discardingAKeyboardSessionDeletesItsRecording() throws {
        let id = UUID()
        let file = try KeyboardRecordingFile(sessionID: id, inputSampleRate: 16_000)
        file.close()
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        var record = SessionRecord(sessionID: id)
        record.localAudioReference = file.url.lastPathComponent
        KeyboardDictation.discardAudio(of: record)
        #expect(FileManager.default.fileExists(atPath: file.url.path))
        record.capturedInKeyboard = true
        KeyboardDictation.discardAudio(of: record)
        #expect(!FileManager.default.fileExists(atPath: file.url.path))
    }

    @MainActor
    @Test func aClosedFileStillFeedsTheStreamButWritesNothing() throws {
        let file = try KeyboardRecordingFile(sessionID: UUID(), inputSampleRate: 16_000)
        defer { try? FileManager.default.removeItem(at: file.url) }
        let chunk = [Int16](repeating: 1_000, count: 1_600).withUnsafeBufferPointer { Data(buffer: $0) }
        file.append(int16: chunk)
        let written = file.frames
        file.close()
        #expect(file.append(int16: chunk) != nil)
        #expect(file.frames == written)
    }

    // MARK: What the app shares with the keyboard

    @Test func streamingIsTriedOnlyWhenTheCurrentModelCanStream() {
        // Read from a health response taken for this dictation: a model swapped
        // on the gateway is followed at once, and an older gateway that says
        // nothing still negotiates on the socket.
        #expect(GatewayStreamingPolicy.attemptsStream(reported: true))
        #expect(!GatewayStreamingPolicy.attemptsStream(reported: false))
        #expect(GatewayStreamingPolicy.attemptsStream(reported: nil))
    }

    @Test func anotherGatewayForgetsWhatTheLastOneSaid() {
        defer { KeyboardGatewayAccess.clear() }
        let first = URL(string: "http://first.local:8765")!
        let second = URL(string: "http://second.local:8765")!
        KeyboardGatewayAccess.publish(baseURL: first, maximumDurationSeconds: 60)
        #expect(KeyboardGatewayAccess.reportedMaximumDurationSeconds == 60)
        KeyboardGatewayAccess.publish(baseURL: second, maximumDurationSeconds: nil)
        #expect(KeyboardGatewayAccess.baseURL == second)
        #expect(KeyboardGatewayAccess.reportedMaximumDurationSeconds == nil)
        KeyboardGatewayAccess.clear()
        #expect(KeyboardGatewayAccess.baseURL == nil)
    }

    // MARK: The recording file

    @MainActor
    @Test func writesMono16kHzWavFromAnyCaptureRate() throws {
        let id = UUID()
        let file = try KeyboardRecordingFile(sessionID: id, inputSampleRate: 48_000)
        defer { try? FileManager.default.removeItem(at: file.url) }
        // One second of a 440 Hz tone at 48 kHz, in WebKit-sized chunks.
        var samples = [Int16]()
        for index in 0..<48_000 {
            samples.append(Int16(sin(Double(index) * 2 * .pi * 440 / 48_000) * 16_000))
        }
        // The same audio comes back as the app's stream format: 16 kHz mono
        // Float32, ready for the gateway while the user is still speaking.
        var streamedBytes = 0
        for start in stride(from: 0, to: samples.count, by: 2_048) {
            let chunk = Array(samples[start..<min(start + 2_048, samples.count)])
            streamedBytes += file.append(int16: chunk.withUnsafeBufferPointer { Data(buffer: $0) })?.count ?? 0
        }
        #expect(streamedBytes.isMultiple(of: 4))
        #expect(abs(Double(streamedBytes / 4) - 16_000) < 800)
        #expect(file.peak > 0.4)
        #expect(abs(file.seconds - 1) < 0.05)
        #expect(file.url.lastPathComponent == "\(id.uuidString).wav")
        #expect(file.url.deletingLastPathComponent().lastPathComponent == "pending-audio")
        let written = try AVAudioFile(forReading: file.url)
        #expect(written.fileFormat.sampleRate == 16_000)
        #expect(written.fileFormat.channelCount == 1)
    }

    @Test func audioReferencesCannotLeaveTheDirectory() {
        #expect(KeyboardRecordingFile.url(for: "../escape.wav") == nil)
        #expect(KeyboardRecordingFile.url(for: "a.wav")?.lastPathComponent == "a.wav")
    }
}
