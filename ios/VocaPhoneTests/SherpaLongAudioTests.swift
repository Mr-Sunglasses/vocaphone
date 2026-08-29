import Testing

/// The iOS half of the chunking and empty-result contract.
///
/// Every test here has a counterpart in Android's `SherpaLongAudioTest`, with
/// the same fixtures and the same expected sample counts. The two platforms
/// drifted apart once already — iOS cut at the single quietest frame and
/// surrendered its overlap where Android required a sustained quiet run and
/// kept context either way — and nothing failed to say so. These are what
/// notice next time.
struct SherpaLongAudioTests {
    private static let rate = SherpaLongAudio.sampleRate

    private static func tone(seconds: Int, amplitude: Float = 0.2) -> [Float] {
        [Float](repeating: amplitude, count: seconds * rate)
    }

    // MARK: - Chunk ranges

    @Test func shortAudioKeepsOneDecodeRange() {
        let chunks = SherpaLongAudio.chunks(Self.tone(seconds: 12, amplitude: 0))

        #expect(chunks.count == 1)
        #expect(chunks[0].start == 0)
        #expect(chunks[0].endExclusive == 192_000)
        #expect(chunks[0].overlapsPrevious == false)
    }

    @Test func continuousLongAudioIsBoundedAndOverlapsEveryBoundary() {
        let samples = Self.tone(seconds: 52)

        let chunks = SherpaLongAudio.chunks(samples)

        let bounded = chunks.allSatisfy { $0.endExclusive - $0.start <= 14 * Self.rate }
        let everyBoundaryOverlaps = chunks.dropFirst().allSatisfy(\.overlapsPrevious)
        let contiguous = zip(chunks, chunks.dropFirst()).allSatisfy { $1.start < $0.endExclusive }

        #expect(chunks.count >= 3)
        #expect(bounded)
        #expect(everyBoundaryOverlaps)
        #expect(contiguous)
        #expect(chunks.last?.endExclusive == samples.count)
    }

    @Test func theEighteenSecondDeviceRegressionIsNeverOneDecode() {
        let samples = Self.tone(seconds: 18)

        let chunks = SherpaLongAudio.chunks(samples)

        let bounded = chunks.allSatisfy { $0.endExclusive - $0.start <= 12 * Self.rate }

        #expect(chunks.count >= 2)
        #expect(bounded)
        #expect(chunks.last?.endExclusive == samples.count)
    }

    // MARK: - Boundary evidence and overlap

    @Test func aQuietBoundaryIsPreferredWithoutSurrenderingOverlap() {
        var samples = Self.tone(seconds: 52)
        let silenceStart = 9 * Self.rate
        let silenceEnd = silenceStart + Self.rate
        for index in silenceStart..<silenceEnd { samples[index] = 0 }

        let chunks = SherpaLongAudio.chunks(samples)

        #expect(chunks[0].overlapsPrevious == false)
        #expect((silenceStart...silenceEnd).contains(chunks[0].endExclusive))
        #expect(chunks[1].overlapsPrevious)
        // A found quiet run still hands context to the next chunk, just less of
        // it than a guessed boundary needs.
        #expect(chunks[1].start == chunks[0].endExclusive - SherpaLongAudio.silenceOverlapSamples)
    }

    @Test func aGuessedBoundaryKeepsTheWiderOverlap() {
        let chunks = SherpaLongAudio.chunks(Self.tone(seconds: 52))

        #expect(chunks[1].start == chunks[0].endExclusive - SherpaLongAudio.overlapSamples)
    }

    /// The bug the sustained-run requirement exists for: a single quiet 100 ms
    /// frame is a low-energy phoneme as often as it is a pause, and cutting
    /// there loses the word around it.
    @Test func oneQuietFrameInsideSpeechIsNotTrustedAsABoundary() {
        var samples = Self.tone(seconds: 30)
        let gap = 10 * Self.rate
        for index in gap..<(gap + Self.rate / 10) { samples[index] = 0 }

        let chunks = SherpaLongAudio.chunks(samples)

        #expect(chunks[0].endExclusive == 10 * Self.rate)
    }

    @Test func streamingSplitReleasesABoundedPrefixWithOverlap() {
        let split = SherpaLongAudio.nextStreamingSplit(
            Self.tone(seconds: SherpaLongAudio.streamingWindowSeconds)
        )

        #expect(split?.endExclusive == 10 * Self.rate)
        #expect(split?.nextStart == 10 * Self.rate - SherpaLongAudio.overlapSamples)
    }

    /// The streaming path retains context at a found boundary too, which is
    /// what makes `overlapsPrevious` true for the chunk after it.
    @Test func aStreamingQuietBoundaryStillRetainsContext() {
        var samples = Self.tone(seconds: SherpaLongAudio.streamingWindowSeconds)
        let silenceStart = 9 * Self.rate
        for index in silenceStart..<(silenceStart + Self.rate) { samples[index] = 0 }

        guard let split = SherpaLongAudio.nextStreamingSplit(samples) else {
            Issue.record("a full streaming window should always split")
            return
        }

        #expect(split.nextStart < split.endExclusive)
        #expect(split.nextStart == split.endExclusive - SherpaLongAudio.silenceOverlapSamples)
    }

    // MARK: - Empty-result recovery

    @Test func anEmptyLongChunkRetriesAsOverlappingShortDecodes() {
        var decodedSizes: [Int] = []
        var shortResult = 0

        let transcript = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 10),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                if samples.count > SherpaLongAudio.minimumSuspectChunkSamples {
                    return .empty
                }
                defer { shortResult += 1 }
                return .decoded(
                    SherpaTranscript(text: shortResult == 0 ? "first half" : "second half")
                )
            },
            deduplicateOverlap: true
        )

        #expect(transcript.transcriptOrEmpty.text == "first half second half")
        // Half the boundary overlap on each side, exactly as Android splits.
        #expect(decodedSizes == [160_000, 84_000, 84_000])
    }

    @Test func anEmptyShortChunkIsNotWorthARetry() {
        var decodedSizes: [Int] = []

        _ = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 5),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                return .empty
            },
            deduplicateOverlap: true
        )

        // Below the suspect bar an empty answer is ordinary — a fragment of a
        // word, or the retained overlap a recording ending just after a
        // boundary leaves — and length is not what dropped it.
        #expect(decodedSizes == [80_000])
    }

    @Test func anAudibleCompleteShortRecordingGetsABoundedFreshStreamRetry() {
        var decodedSizes: [Int] = []
        var attempts = 0

        let transcript = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 5),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                defer { attempts += 1 }
                return .decoded(SherpaTranscript(text: attempts == 1 ? "recovered" : ""))
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        #expect(transcript.transcriptOrEmpty.text == "recovered")
        #expect(decodedSizes == [80_000, 80_000])
    }

    @Test func aShortRecordingStillEmptyOnAFreshStreamIsPaddedThenSplit() {
        var decodedSizes: [Int] = []

        _ = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 3),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                return .empty
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        // Whole, whole again, padded half a second either side, then the two
        // halves. The ladder is fixed-length: it never subdivides again.
        #expect(decodedSizes == [48_000, 48_000, 64_000, 28_000, 28_000])
    }

    /// The extra rungs are for short speech. A long first chunk with nothing
    /// decoded ahead of it is still a long window: repeating it and padding it
    /// costs two whole further decodes and recovers what the split already does.
    @Test func aLongWindowKeepsTheSplitLadderEvenWithNothingDecodedBeforeIt() {
        var decodedSizes: [Int] = []

        _ = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 10),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                return .empty
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        #expect(decodedSizes == [160_000, 84_000, 84_000])
    }

    /// A very short recording must not hand both halves the whole waveform.
    @Test func theRecoverySplitNeverDecodesTheWholeWaveformTwice() {
        var decodedSizes: [Int] = []

        _ = SherpaEmptyChunkRecovery.decode(
            samples: [Float](repeating: 0.2, count: Self.rate / 4),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                return .empty
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        let bothHalvesAreSmaller = decodedSizes.suffix(2).allSatisfy { $0 < Self.rate / 4 }
        #expect(bothHalvesAreSmaller)
    }

    @Test func aSilentChunkIsNeverRetried() {
        var decodedSizes: [Int] = []

        _ = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 10, amplitude: 0),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                return .empty
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        // Not one decode: room tone answering with nothing is the right answer,
        // and it is ruled out before any inference is spent.
        #expect(decodedSizes.isEmpty)
    }

    @Test func aHalfThatIsStillEmptyIsNotSubdividedAgain() {
        var decodedSizes: [Int] = []

        _ = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 14),
            decodeOnce: { samples in
                decodedSizes.append(samples.count)
                return .empty
            },
            deduplicateOverlap: true
        )

        #expect(decodedSizes == [224_000, 116_000, 116_000])
    }

    /// Translated windows are joined verbatim: the same audio does not come
    /// back as the same words, so nothing can pair the repeat.
    @Test func aTranslatedRecoverySplitIsNeverTextDeduplicated() {
        let transcript = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 10),
            decodeOnce: { samples in
                samples.count > SherpaLongAudio.minimumSuspectChunkSamples
                    ? .empty
                    : .decoded(SherpaTranscript(text: "to the shop"))
            },
            deduplicateOverlap: false
        )

        #expect(transcript.transcriptOrEmpty.text == "to the shop to the shop")
    }

    // MARK: - Native failures never enter the ladder

    /// The amplification the typed outcome removes. A recognizer that will not
    /// open a stream answers with no text, and the ladder used to read that as
    /// a model with nothing to say — spending four more decodes on the same
    /// broken state and then reporting it as an empty transcript.
    @Test func aNativeFailureStopsTheLadderAtOnce() {
        var attempts = 0

        let outcome = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 3),
            decodeOnce: { _ in
                attempts += 1
                return .failed(.streamUnavailable)
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        #expect(attempts == 1)
        #expect(outcome.nativeFailure == .streamUnavailable)
    }

    /// Including partway up the ladder: the first decode can answer and a later
    /// rung still find the engine gone.
    @Test func aNativeFailureOnARetryIsNotReadAsAnEmptyResult() {
        var attempts = 0

        let outcome = SherpaEmptyChunkRecovery.decode(
            samples: Self.tone(seconds: 3),
            decodeOnce: { _ in
                attempts += 1
                return attempts == 1 ? .empty : .failed(.resultMissing)
            },
            deduplicateOverlap: true,
            recoverAudibleShortInput: true
        )

        #expect(attempts == 2)
        #expect(outcome.nativeFailure == .resultMissing)
    }

    /// A truncated transcript is the opposite failure to an empty one — text was
    /// produced and lost — and must never be reported as no speech.
    @Test func everyBridgeStatusMapsToItsOwnFailure() {
        #expect(SherpaNativeFailure.forStatus(-1) == .invalidArgument)
        #expect(SherpaNativeFailure.forStatus(-2) == .streamUnavailable)
        #expect(SherpaNativeFailure.forStatus(-3) == .resultMissing)
        #expect(SherpaNativeFailure.forStatus(-4) == .outputTruncated)
        // A status the bridge grows later must not read as a successful decode.
        #expect(SherpaNativeFailure.forStatus(-99) == .unknown)
    }

    // MARK: - Merge width

    @Test func overlappedWordsAreMergedOnce() {
        #expect(SherpaTranscriptMerger.append(existing: "hello world", next: "world again")
            == "hello world again")
        #expect(SherpaTranscriptMerger.append(existing: "Hello", next: "Hello, there.")
            == "Hello, there.")
        #expect(SherpaTranscriptMerger.append(
            existing: "yes", next: "yes", deduplicateOverlap: false
        ) == "yes yes")
    }

    /// The audio overlap is half a second at most, so a match wider than that
    /// can only be a phrase the speaker genuinely repeated. Deleting it is the
    /// worse error, and iOS used to allow a match three times too wide.
    @Test func aPhraseWiderThanTheAudioOverlapIsPreservedAsRepetition() {
        #expect(SherpaTranscriptMerger.append(
            existing: "start one two three four five",
            next: "one two three four five end"
        ) == "start one two three four five one two three four five end")
    }

    @Test func deduplicationRemovesARepetitionThatTranslatingMustKeep() {
        let left = "I went to the shop"
        let right = "to the shop and then home"

        #expect(SherpaTranscriptMerger.append(
            existing: left, next: right, deduplicateOverlap: true
        ) == "I went to the shop and then home")
        #expect(SherpaTranscriptMerger.append(
            existing: left, next: right, deduplicateOverlap: false
        ) == "I went to the shop to the shop and then home")
    }
}
