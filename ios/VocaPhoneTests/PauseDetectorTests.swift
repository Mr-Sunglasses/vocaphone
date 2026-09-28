import Testing

/// When Stop after a pause ends a dictation.
struct PauseDetectorTests {
    /// Feeds `seconds` of one RMS level in 50 ms steps; true if it fired.
    private func feed(_ detector: inout PauseDetector, rms: Float, seconds: Double) -> Bool {
        var fired = false
        for _ in 0..<Int((seconds / 0.05).rounded()) {
            fired = detector.observe(rms: rms, seconds: 0.05) || fired
        }
        return fired
    }

    @Test func speechThenThreeSecondsOfQuietFinishes() {
        var detector = PauseDetector()
        #expect(!feed(&detector, rms: 0.001, seconds: 1))
        #expect(!feed(&detector, rms: 0.05, seconds: 2))
        #expect(!feed(&detector, rms: 0.001, seconds: 2.9))
        #expect(feed(&detector, rms: 0.001, seconds: 0.2))
    }

    /// A pause shorter than three seconds is someone thinking.
    @Test func aShortPauseDoesNotFinish() {
        var detector = PauseDetector()
        _ = feed(&detector, rms: 0.001, seconds: 1)
        _ = feed(&detector, rms: 0.05, seconds: 2)
        #expect(!feed(&detector, rms: 0.001, seconds: 2))
        #expect(!feed(&detector, rms: 0.05, seconds: 0.5))
        #expect(!feed(&detector, rms: 0.001, seconds: 2.5))
    }

    /// Nothing counts before a full second of speech: a recording started
    /// before the user has gathered their thoughts must not end on its own.
    @Test func silenceBeforeSpeechNeverFinishes() {
        var detector = PauseDetector()
        #expect(!feed(&detector, rms: 0.001, seconds: 10))
        #expect(!feed(&detector, rms: 0.05, seconds: 0.5))
        #expect(!feed(&detector, rms: 0.001, seconds: 5))
    }

    /// A steady fan is the floor, not speech; speech over it still counts,
    /// and the fan alone after it is the pause.
    @Test func aNoisyRoomIsTheFloor() {
        var detector = PauseDetector()
        #expect(!feed(&detector, rms: 0.02, seconds: 5))
        #expect(!feed(&detector, rms: 0.15, seconds: 2))
        #expect(feed(&detector, rms: 0.02, seconds: 3.1))
    }
}
