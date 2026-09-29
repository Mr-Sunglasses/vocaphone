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

    /// A fan that switches on after the speech is heard as speech at first and
    /// then absorbed into the floor — at no point is it the pause.
    @Test func aFanSwitchingOnNeverEndsTheRecording() {
        var detector = PauseDetector()
        _ = feed(&detector, rms: 0.001, seconds: 1)
        _ = feed(&detector, rms: 0.05, seconds: 2)
        #expect(!feed(&detector, rms: 0.03, seconds: 120))
    }

    /// Quiet speech over steady background, about 9 dB apart: the background
    /// after it is still the pause.
    @Test func quietSpeechOverBackgroundStillStops() {
        var detector = PauseDetector()
        _ = feed(&detector, rms: 0.001, seconds: 1)
        _ = feed(&detector, rms: 0.02, seconds: 2)
        // Three seconds of pause, after 0.6 s to hear that the background is
        // steady rather than softer speech.
        #expect(!feed(&detector, rms: 0.007, seconds: 3.4))
        #expect(feed(&detector, rms: 0.007, seconds: 0.4))
    }

    /// Someone carrying on more softly, at the same level steady background
    /// would sit at: it rises and falls with each syllable, so it is not the
    /// pause.
    @Test func softerSpeechIsNotAPause() {
        var detector = PauseDetector()
        _ = feed(&detector, rms: 0.001, seconds: 1)
        _ = feed(&detector, rms: 0.02, seconds: 2)
        var fired = false
        for step in 0..<120 {
            fired = detector.observe(rms: step.isMultiple(of: 3) ? 0.002 : 0.007, seconds: 0.05) || fired
        }
        #expect(!fired)
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
