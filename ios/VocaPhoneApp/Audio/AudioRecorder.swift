import AVFAudio
import Foundation
import os

enum AudioSessionLifecycleEvent: Equatable, Sendable {
    case interruptionBegan
    case interruptionEnded(shouldResume: Bool)
    case mediaServicesReset
    case inputUnavailable
}

@MainActor
final class AudioRecorder: NSObject {
    private var engine: AVAudioEngine?
    private var captureFormat: AVAudioFormat?
    private var ring: PCMRingBuffer?
    private var tap: CaptureTap?
    private var pipeline: AudioCapturePipeline?
    private var chunkContinuation: AsyncStream<Data>.Continuation?
    private var localChunkContinuation: AsyncStream<Data>.Continuation?
    private var outputURL: URL?
    private var meterTimer: Timer?
    private var limitTimer: Timer?
    nonisolated(unsafe) private var lifecycleObservers: [any NSObjectProtocol] = []
    var onMeter: ((Float) -> Void)?
    var onMaximumDuration: (() -> Void)?
    var onInputRouteChanged: ((String?) -> Void)?
    var onAudioSessionLifecycleEvent: ((AudioSessionLifecycleEvent) -> Void)?
    var microphonePreference: MicrophonePreference = .automatic

    /// Chunks of float32 PCM at the transcription sample rate, in order. Backed
    /// by a bounded buffer: if the transport cannot keep up the stream is
    /// abandoned rather than growing without limit, and the intact file on disk
    /// becomes the fallback.
    private(set) var pcmChunks: AsyncStream<Data>?
    /// A separate, lossless-enough queue for on-device Sherpa. Unlike the
    /// gateway queue, it is sized for the complete recording so model loading
    /// or a slower first decode cannot discard the beginning of the transcript.
    private(set) var localPcmChunks: AsyncStream<Data>?
    private(set) var lastDroppedChunkCount = 0
    /// Whether the on-device queue refused a chunk. Its capacity is comfortably
    /// past the recording limit, so this should never fire — but the two numbers
    /// are set in different files, and the failure it guards is silent: a
    /// refused chunk is seconds missing from the end of the transcript with
    /// nothing in the text to show for it.
    private let localChunksDropped = OSAllocatedUnfairLock(initialState: false)
    var didDropLocalChunks: Bool { localChunksDropped.withLock { $0 } }
    /// The loudest sample of the recording that just finished. Zero means iOS
    /// handed this app silence, not that the user said nothing quietly.
    private(set) var lastPeakLevel: Float = 0

    override init() {
        super.init()
        let center = NotificationCenter.default
        let session = AVAudioSession.sharedInstance()
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawReason = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleRouteChange(rawReason: rawReason)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.interruptionNotification,
            object: session,
            queue: .main
        ) { [weak self] notification in
            let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
            let rawOptions = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt
            MainActor.assumeIsolated {
                self?.handleInterruption(rawType: rawType, rawOptions: rawOptions)
            }
        })
        lifecycleObservers.append(center.addObserver(
            forName: AVAudioSession.mediaServicesWereResetNotification,
            object: session,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.onAudioSessionLifecycleEvent?(.mediaServicesReset)
            }
        })
    }

    deinit {
        for observer in lifecycleObservers {
            NotificationCenter.default.removeObserver(observer)
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

    /// Attempts at a microphone another app is in the middle of releasing.
    private static let startAttempts = 3
    /// Long enough for a call teardown or a broadcast handoff to complete.
    private static let startRetryMilliseconds = 150

    /// Warms the same graph `start` will capture from. Recording feedback can
    /// therefore play before the tap starts without paying a second setup cost.
    ///
    /// Another app letting go of the microphone — a call ending, a screen
    /// recording stopping — is not instantaneous, and iOS reports that gap as an
    /// ordinary activation failure. Retrying across it turns a dictation that
    /// would have been lost into one that starts a moment late.
    func prepareForRecording() async throws {
        var lastError: (any Error)?
        for attempt in 0..<Self.startAttempts {
            if attempt > 0 {
                try? await Task.sleep(for: .milliseconds(Self.startRetryMilliseconds))
            }
            do {
                try ensureEngineRunning()
                return
            } catch {
                lastError = error
            }
        }
        throw Self.startFailure(lastError)
    }

    /// The same activation failure means different things to the user depending
    /// on who else holds the input, so it is read once here rather than shown
    /// raw as an unexplained Core Audio message.
    private static func startFailure(_ error: (any Error)?) -> any Error {
        guard let error else { return RecordingError.inputUnavailable }
        if error is RecordingError { return error }
        guard let code = AVAudioSession.ErrorCode(rawValue: (error as NSError).code) else {
            return error
        }
        switch code {
        case .isBusy, .cannotStartRecording, .cannotInterruptOthers,
             .siriIsRecording, .insufficientPriority, .resourceNotAvailable:
            return RecordingError.microphoneBusy
        default:
            return error
        }
    }

    /// Starts writing from the already-running microphone engine. When Quick
    /// Dictation is armed, this does not stop or rebuild the audio graph.
    func start(
        sessionID: UUID,
        directory: URL,
        includeLocalModelChunks: Bool = false
    ) throws -> URL {
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

        var localContinuation: AsyncStream<Data>.Continuation?
        let localStream: AsyncStream<Data>?
        if includeLocalModelChunks {
            localStream = AsyncStream<Data>(bufferingPolicy: .bufferingOldest(2_048)) {
                localContinuation = $0
            }
        } else {
            localStream = nil
        }

        ring.reset()
        // Captured rather than reached through `self`: the emit closure runs on
        // the capture queue and this type is main-actor isolated.
        let localDropped = localChunksDropped
        localDropped.withLock { $0 = false }
        try pipeline.start(writingTo: output) { data in
            let gatewayAccepted = switch continuation.yield(data) {
            case .enqueued: true
            default: false
            }
            if let localContinuation {
                switch localContinuation.yield(data) {
                case .enqueued: break
                default: localDropped.withLock { $0 = true }
                }
            }
            return gatewayAccepted
        }

        self.pipeline = pipeline
        chunkContinuation = continuation
        pcmChunks = stream
        localChunkContinuation = localContinuation
        localPcmChunks = localStream
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
        lastPeakLevel = pipeline?.peakLevel ?? 0
        chunkContinuation?.finish()
        chunkContinuation = nil
        pcmChunks = nil
        localChunkContinuation?.finish()
        localChunkContinuation = nil
        localPcmChunks = nil
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

    private func handleRouteChange(rawReason: UInt?) {
        publishCurrentInput()
        guard let rawReason,
              AVAudioSession.RouteChangeReason(rawValue: rawReason) == .oldDeviceUnavailable,
              AVAudioSession.sharedInstance().currentRoute.inputs.isEmpty
        else { return }
        onAudioSessionLifecycleEvent?(.inputUnavailable)
    }

    private func handleInterruption(rawType: UInt?, rawOptions: UInt?) {
        guard let rawType,
              let type = AVAudioSession.InterruptionType(rawValue: rawType)
        else { return }
        switch type {
        case .began:
            onAudioSessionLifecycleEvent?(.interruptionBegan)
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions(rawValue: rawOptions ?? 0)
                .contains(.shouldResume)
            onAudioSessionLifecycleEvent?(.interruptionEnded(shouldResume: shouldResume))
        @unknown default:
            onAudioSessionLifecycleEvent?(.interruptionBegan)
        }
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
    case microphoneBusy

    var errorDescription: String? {
        switch self {
        case .alreadyRecording:
            "Another recording is already active."
        case .inputUnavailable:
            "The microphone input is unavailable."
        case .iPhoneMicrophoneUnavailable:
            "The iPhone microphone is not currently available."
        case .microphoneBusy:
            "Another app or a call is using the microphone. "
                + "Stop that recording, or wait for the call to end, and try again."
        }
    }
}
