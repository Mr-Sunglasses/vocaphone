import AVFAudio
import Foundation
import os

@MainActor
final class AudioRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var captureFormat: AVAudioFormat?
    private var ring: PCMRingBuffer?
    private var tap: CaptureTap?
    private var pipeline: AudioCapturePipeline?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var outputURL: URL?
    private var meterTimer: Timer?
    private var limitTimer: Timer?
    nonisolated(unsafe) private var routeChangeObserver: (any NSObjectProtocol)?
    var onMeter: ((Float) -> Void)?
    var onMaximumDuration: (() -> Void)?
    var onInputRouteChanged: ((String?) -> Void)?
    var microphonePreference: MicrophonePreference = .automatic

    /// Chunks of float32 PCM at the transcription sample rate, in order. Backed
    /// by a bounded buffer: if the transport cannot keep up the stream is
    /// abandoned rather than growing without limit, and the intact file on disk
    /// becomes the fallback.
    private(set) var pcmChunks: AsyncStream<Data>?
    private(set) var lastDroppedChunkCount = 0

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

    var isRecording: Bool { outputURL != nil && pipeline != nil }
    var isStandbyActive: Bool { engine?.isRunning == true && !isRecording }
    var currentInputName: String? {
        guard engine?.isRunning == true else { return nil }
        return AVAudioSession.sharedInstance().currentRoute.inputs.first?.portName
    }
    var recordPermission: AVAudioApplication.recordPermission {
        AVAudioApplication.shared.recordPermission
    }
    /// The rate the gateway is told about, which is the converted rate rather
    /// than whatever the hardware happened to offer.
    var transcriptionSampleRate: Double { CaptureFormat.sampleRate }

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
        guard let captureFormat, let ring, let tap else {
            throw RecordingError.inputUnavailable
        }
        guard let pipeline = AudioCapturePipeline(
            sourceSampleRate: captureFormat.sampleRate,
            ring: ring
        ) else {
            throw RecordingError.inputUnavailable
        }

        var continuation: AsyncStream<Data>.Continuation?
        // Roughly five seconds of audio in flight. Past that the link is not
        // going to recover within the recording, so dropping and falling back
        // beats holding megabytes of PCM in memory.
        let stream = AsyncStream<Data>(bufferingPolicy: .bufferingNewest(48)) {
            continuation = $0
        }
        guard let continuation else { throw RecordingError.inputUnavailable }

        ring.reset()
        try pipeline.start(writingTo: output) { data in
            switch continuation.yield(data) {
            case .enqueued: true
            default: false
            }
        }

        self.pipeline = pipeline
        chunkContinuation = continuation
        pcmChunks = stream
        lastDroppedChunkCount = 0
        outputURL = output
        tap.isCapturing = true

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
        teardownCapture()
        if !keepAudioSessionActive {
            stopEngine(deactivateAudioSession: true)
        }
        return finishedOutput
    }

    func cancelSession(keepAudioSessionActive: Bool = false) {
        let canceledOutput = outputURL
        teardownCapture()
        if let canceledOutput {
            try? FileManager.default.removeItem(at: canceledOutput)
        }
        if !keepAudioSessionActive {
            stopEngine(deactivateAudioSession: true)
        }
    }

    /// Keeps the containing app eligible for background audio execution while
    /// discarding every captured buffer. No standby audio reaches the ring.
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

    private func teardownCapture() {
        tap?.isCapturing = false
        // Drains what the ring still holds and closes the file before the
        // caller uploads it.
        pipeline?.finish()
        lastDroppedChunkCount = (pipeline?.droppedChunkCount ?? 0) + (ring?.overflowCount ?? 0)
        chunkContinuation?.finish()
        chunkContinuation = nil
        pcmChunks = nil
        pipeline = nil
        outputURL = nil
        stopTimers()
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
        // Two seconds of headroom between the render thread and the drain tick.
        let buffer = PCMRingBuffer(capacity: Int(format.sampleRate * 2))
        let captureTap = CaptureTap(ring: buffer)
        input.installTap(onBus: 0, bufferSize: 4_096, format: format) {
            @Sendable buffer, _ in
            captureTap.consume(buffer)
        }
        newEngine.prepare()
        do {
            try newEngine.start()
            engine = newEngine
            captureFormat = format
            ring = buffer
            tap = captureTap
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
            tap = nil
            ring = nil
        }
        if deactivateAudioSession {
            self.deactivateAudioSession()
        }
        publishCurrentInput()
    }

    private func sampleMeter() {
        guard let pipeline else { return }
        onMeter?(pipeline.meterLevel)
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

/// Everything the CoreAudio render thread is allowed to touch. The callback
/// copies samples into a preallocated ring and returns: no allocation, no file
/// access, no task creation, and no lock held longer than a word write.
private final class CaptureTap: @unchecked Sendable {
    private let ring: PCMRingBuffer
    private let capturing = OSAllocatedUnfairLock(initialState: false)

    init(ring: PCMRingBuffer) {
        self.ring = ring
    }

    var isCapturing: Bool {
        get { capturing.withLock { $0 } }
        set { capturing.withLock { $0 = newValue } }
    }

    func consume(_ buffer: AVAudioPCMBuffer) {
        guard capturing.withLock({ $0 }),
              let channel = buffer.floatChannelData?[0],
              buffer.frameLength > 0
        else { return }
        ring.write(channel, count: Int(buffer.frameLength))
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
