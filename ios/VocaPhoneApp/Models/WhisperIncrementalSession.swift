import Foundation

/// Listens to a Whisper dictation while it is being recorded, and decodes it
/// early whenever the speaker pauses.
///
/// Whisper decodes thirty-second windows, and until this every one of them was
/// decoded after Finish — the whole of a short dictation's wait. Now each pause
/// hands the recording so far to `decodeEarly`, which fills the dictation's
/// `WhisperWindowCache`. At Finish, the recording is trimmed after its last
/// word the same way that early decode was, so when nothing more was said,
/// every window it needs is already in the cache and Finish decodes nothing.
/// When more was said, only the windows that changed are decoded.
///
/// The WAV file stays authoritative: a caller whose capture queue dropped a
/// chunk does not use this, and decodes the file as before.
actor WhisperIncrementalSession {
    /// The recording as captured, cut after its last word.
    struct Audio: Sendable {
        let samples: [Float]
        /// Samples of trailing non-speech left out.
        let trimmedSamples: Int
    }

    private var samples: [Float] = []
    private var regions: [SpeechRegion] = []
    private let makeDetector: @Sendable () -> SpeechActivityDetecting?
    private var detector: SpeechActivityDetecting?
    private var detectorMade = false
    private let chunks: AsyncStream<Data>
    private var consumer: Task<Void, Never>?

    private let decodeEarly: @Sendable ([Float]) async -> Void
    /// The early decode in flight, and the recording length it is decoding.
    private var running: (task: Task<Void, Never>, end: Int)?
    /// The latest pause not yet decoded.
    private var pendingEnd: Int?
    private var finished = false

    /// `detector` is called once, on this actor; nil — or a detector that
    /// cannot load — records without early decoding or trimming.
    /// `decodeEarly` is handed the recording up to just after a word the
    /// speaker has paused after, one call at a time, latest pause first.
    init(
        chunks: AsyncStream<Data>,
        detector: @escaping @Sendable () -> SpeechActivityDetecting?,
        decodeEarly: @escaping @Sendable ([Float]) async -> Void
    ) {
        makeDetector = detector
        self.decodeEarly = decodeEarly
        self.chunks = chunks
        // The capture queue holds everything until it is read, so starting a
        // moment late loses nothing.
        Task { await self.startConsuming() }
    }

    /// Reads the capture as it arrives. Whichever of the start and `finish`
    /// gets here first begins it; a stream can only be read once.
    private func startConsuming() {
        guard consumer == nil else { return }
        consumer = Task {
            for await data in chunks {
                guard !Task.isCancelled else { return }
                take(data)
            }
        }
    }

    private func take(_ data: Data) {
        guard !finished else { return }
        if !detectorMade {
            detectorMade = true
            detector = makeDetector()
        }
        let incoming = Self.floatSamples(in: data)
        samples.append(contentsOf: incoming)
        let closed = detector?.accept(incoming) ?? []
        guard !closed.isEmpty else { return }
        regions += closed
        let end = min(regions.last!.end + SpeechActivity.tailPaddingSamples, samples.count)
        pendingEnd = end
        startPendingDecode()
    }

    private func startPendingDecode() {
        guard running == nil, !finished, let end = pendingEnd else { return }
        pendingEnd = nil
        let prefix = Array(samples[..<end])
        let decodeEarly = decodeEarly
        let task = Task {
            await decodeEarly(prefix)
            self.decodeFinished()
        }
        running = (task, end)
    }

    private func decodeFinished() {
        running = nil
        startPendingDecode()
    }

    /// Everything captured, cut after the last word. An early decode of
    /// exactly that audio is waited for, since it is producing the answer;
    /// one of anything else is stopped, since nothing will read it.
    ///
    /// Call after the capture stream has finished.
    func finish() async -> Audio {
        startConsuming()
        await consumer?.value
        finished = true
        pendingEnd = nil
        regions += detector?.finish() ?? []
        detector = nil
        let end = SpeechActivity.trimmedEnd(of: samples, regions: regions) ?? samples.count
        if let running {
            if running.end != end { running.task.cancel() }
            await running.task.value
        }
        return Audio(samples: Array(samples[..<end]), trimmedSamples: samples.count - end)
    }

    /// Stops listening and any early decode, for a dictation that will not be
    /// transcribed this way.
    func cancel() {
        finished = true
        pendingEnd = nil
        consumer?.cancel()
        running?.task.cancel()
        detector = nil
    }

    private static func floatSamples(in data: Data) -> [Float] {
        guard data.count >= MemoryLayout<Float>.stride else { return [] }
        return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
    }
}
