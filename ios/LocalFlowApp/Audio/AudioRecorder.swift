import AVFAudio
import Foundation

@MainActor
final class AudioRecorder: NSObject {
    private let captureSink = AudioCaptureSink()
    private var engine: AVAudioEngine?
    private var captureFormat: AVAudioFormat?
    private var outputURL: URL?
    private var meterTimer: Timer?
    private var limitTimer: Timer?
    nonisolated(unsafe) private var routeChangeObserver: (any NSObjectProtocol)?
    var onMeter: ((Float) -> Void)?
    var onMaximumDuration: (() -> Void)?
    var onInputRouteChanged: ((String?) -> Void)?
    var onPCMChunk: (@Sendable (Data, UInt64) -> Void)? {
        didSet { captureSink.onPCMChunk = onPCMChunk }
    }
    var microphonePreference: MicrophonePreference = .automatic

    override init() {
        super.init()
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.publishCurrentInput()
            }
        }
    }

    deinit {
        if let routeChangeObserver {
            NotificationCenter.default.removeObserver(routeChangeObserver)
        }
    }

    var isRecording: Bool { outputURL != nil && captureSink.isWriting }
    var isStandbyActive: Bool { engine?.isRunning == true && !isRecording }
    var currentInputName: String? {
        guard engine?.isRunning == true else { return nil }
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }
    var recordPermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }
    var recordingSampleRate: Double? { captureFormat?.sampleRate }
    private(set) var lastFinishedChunkCount: UInt64 = 0

    func requestPermission(
        _ completion: @escaping @MainActor @Sendable (Bool) -> Void
    ) {
        AVAudioApplication.requestRecordPermission { granted in
            Task { @MainActor in completion(granted) }
        }
    }

    /// Starts writing from the already-running microphone engine. When Quick
    /// Dictation is armed, this does not stop or rebuild the audio graph.
    func start(sessionID: UUID, directory: URL) throws -> URL {
        guard !isRecording else { throw RecordingError.alreadyRecording }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let output = directory
            .appendingPathComponent(sessionID.uuidString.lowercased())
            .appendingPathExtension("wav")

        try ensureEngineRunning()
        guard let captureFormat else { throw RecordingError.inputUnavailable }
        let file = try AVAudioFile(
            forWriting: output,
            settings: captureFormat.settings,
            commonFormat: captureFormat.commonFormat,
            interleaved: captureFormat.isInterleaved
        )
        captureSink.beginWriting(to: file)
        lastFinishedChunkCount = 0
        outputURL = output

        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.15, repeats: true) {
            [weak self] _ in
            MainActor.assumeIsolated { self?.sampleMeter() }
        }
        limitTimer = Timer.scheduledTimer(
            withTimeInterval: AppConfiguration.maximumRecordingSeconds,
            repeats: false
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.onMaximumDuration?() }
        }
        return output
    }

    /// Finishes the file while optionally leaving the exact same audio engine
    /// running. Keeping one graph alive avoids the background suspension race
    /// that otherwise forces the user back into the containing app after every
    /// transcript.
    func stopSession(keepAudioSessionActive: Bool = false) -> URL? {
        let finishedOutput = outputURL
        lastFinishedChunkCount = captureSink.finishWriting()
        outputURL = nil
        stopTimers()
        if !keepAudioSessionActive {
            stopEngine(deactivateAudioSession: true)
        }
        return finishedOutput
    }

    func cancelSession(keepAudioSessionActive: Bool = false) {
        let canceledOutput = outputURL
        _ = captureSink.finishWriting()
        outputURL = nil
        stopTimers()
        if let canceledOutput {
            try? FileManager.default.removeItem(at: canceledOutput)
        }
        if !keepAudioSessionActive {
            stopEngine(deactivateAudioSession: true)
        }
    }

    /// Keeps the containing app eligible for background audio execution while
    /// discarding every captured buffer. No standby audio is written to disk.
    func startStandby() throws {
        guard !isRecording else { return }
        try ensureEngineRunning()
    }

    func stopStandby(deactivateAudioSession: Bool = true) {
        guard !isRecording else { return }
        stopEngine(deactivateAudioSession: deactivateAudioSession)
    }

    func stopAll() {
        if isRecording {
            cancelSession(keepAudioSessionActive: true)
        }
        stopEngine(deactivateAudioSession: true)
    }

    private func ensureEngineRunning() throws {
        if engine?.isRunning == true {
            let currentInput = AVAudioSession.sharedInstance().currentRoute.inputs.first
            if microphonePreference != .iPhone || currentInput?.portType == .builtInMic {
                return
            }
            // An external route can override the preference while Quick Dictation
            // is standing by. Rebuild the graph before recording so the selected
            // built-in input and its hardware format are both applied.
        }
        stopEngine(deactivateAudioSession: false)

        let audioSession = AVAudioSession.sharedInstance()
        // playAndRecord otherwise defaults media output to the receiver. Make
        // the built-in speaker the default without forcing a port override, so
        // connected headphones and Bluetooth routes can still be selected.
        var categoryOptions: AVAudioSession.CategoryOptions = [
            .mixWithOthers,
            .defaultToSpeaker,
        ]
#if compiler(>=6.2)
        categoryOptions.insert(.allowBluetoothHFP)
#else
        categoryOptions.insert(.allowBluetooth)
#endif
        try audioSession.setCategory(
            .playAndRecord,
            mode: .default,
            options: categoryOptions
        )
        do {
            try audioSession.setActive(true)
            try selectPreferredInput(in: audioSession)
        } catch {
            deactivateAudioSession()
            throw error
        }

        let newEngine = AVAudioEngine()
        let input = newEngine.inputNode
        let format = input.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            deactivateAudioSession()
            throw RecordingError.inputUnavailable
        }
        let sink = captureSink
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) {
            @Sendable buffer, _ in
            sink.consume(buffer)
        }
        newEngine.prepare()
        do {
            try newEngine.start()
            engine = newEngine
            captureFormat = format
            publishCurrentInput()
        } catch {
            input.removeTap(onBus: 0)
            deactivateAudioSession()
            throw error
        }
    }

    private func stopEngine(deactivateAudioSession: Bool) {
        if let engine {
            engine.stop()
            engine.inputNode.removeTap(onBus: 0)
            self.engine = nil
            captureFormat = nil
        }
        if deactivateAudioSession {
            self.deactivateAudioSession()
        }
        publishCurrentInput()
    }

    private func sampleMeter() {
        guard isRecording else { return }
        onMeter?(captureSink.meterLevel)
    }

    private func stopTimers() {
        meterTimer?.invalidate()
        limitTimer?.invalidate()
        meterTimer = nil
        limitTimer = nil
    }

    private func deactivateAudioSession() {
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func selectPreferredInput(in audioSession: AVAudioSession) throws {
        switch microphonePreference {
        case .automatic:
            try audioSession.setPreferredInput(nil)
        case .iPhone:
            guard let builtInMicrophone = audioSession.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) else {
                throw RecordingError.iPhoneMicrophoneUnavailable
            }
            try audioSession.setPreferredInput(builtInMicrophone)
        }
    }

    private func publishCurrentInput() {
        onInputRouteChanged?(currentInputName)
    }
}

/// The audio tap runs on a realtime queue, not the main actor. This small sink
/// owns the file behind a lock so the tap can safely switch between discarding
/// standby buffers and writing an active dictation without rebuilding audio.
private final class AudioCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private var file: AVAudioFile?
    private var latestMeterLevel: Float = 0
    var onPCMChunk: (@Sendable (Data, UInt64) -> Void)?
    private var nextSequence: UInt64 = 0

    var isWriting: Bool {
        lock.withLock { file != nil }
    }

    var meterLevel: Float {
        lock.withLock { latestMeterLevel }
    }

    func beginWriting(to file: AVAudioFile) {
        lock.withLock {
            self.file = file
            latestMeterLevel = 0
            nextSequence = 0
        }
    }

    func finishWriting() -> UInt64 {
        lock.withLock {
            let chunkCount = nextSequence
            file = nil
            latestMeterLevel = 0
            return chunkCount
        }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        lock.withLock {
            guard let file else { return }
            do {
                try file.write(from: buffer)
                latestMeterLevel = Self.normalizedMeterLevel(buffer)
                if let samples = buffer.floatChannelData?[0], buffer.frameLength > 0 {
                    let data = Data(
                        bytes: samples,
                        count: Int(buffer.frameLength) * MemoryLayout<Float>.size
                    )
                    let sequence = nextSequence
                    nextSequence += 1
                    onPCMChunk?(data, sequence)
                }
            } catch {
                // The coordinator detects a missing/invalid output during
                // finalization and preserves a recoverable session state.
                self.file = nil
                latestMeterLevel = 0
            }
        }
    }

    private static func normalizedMeterLevel(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let channels = buffer.floatChannelData,
              buffer.frameLength > 0
        else { return 0 }
        let samples = channels[0]
        var sum: Float = 0
        for index in 0..<Int(buffer.frameLength) {
            let value = samples[index]
            sum += value * value
        }
        let rms = sqrt(sum / Float(buffer.frameLength))
        let decibels = 20 * log10(max(rms, 0.000_001))
        return max(0, min(1, pow(10, decibels / 40)))
    }
}

enum RecordingError: LocalizedError {
    case alreadyRecording
    case inputUnavailable
    case iPhoneMicrophoneUnavailable

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Another recording is already active."
        case .inputUnavailable:
            "The microphone input is unavailable."
        case .iPhoneMicrophoneUnavailable:
            "The iPhone microphone is not currently available."
        }
    }
}
