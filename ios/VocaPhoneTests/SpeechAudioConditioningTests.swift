import Foundation
import Testing

struct SpeechAudioConditioningTests {
    private func tone(peak: Float, offset: Float = 0, count: Int = 16_000) -> [Float] {
        (0..<count).map { index in peak * Float(sin(Double(index) * 0.05)) + offset }
    }

    private func peak(_ samples: [Float]) -> Float {
        samples.reduce(0) { max($0, abs($1)) }
    }

    @Test func aQuietRecordingIsBroughtUpToTheTargetLevel() {
        // 0.85/0.2 is well inside the gain ceiling, so the target is reached.
        let conditioned = SpeechAudioConditioning.condition(tone(peak: 0.2))
        #expect(abs(peak(conditioned) - 0.85) < 0.02)
    }

    @Test func theBoostIsCappedSoANoiseFloorNeverBecomesFullScale() {
        // 0.85/0.02 would be 42x; the ceiling is 8x.
        let conditioned = SpeechAudioConditioning.condition(tone(peak: 0.02))
        #expect(abs(peak(conditioned) - 0.16) < 0.01)
    }

    @Test func anAlreadyLoudRecordingIsNotAmplified() {
        let original = tone(peak: 0.95)
        let conditioned = SpeechAudioConditioning.condition(original)
        // Only the residual DC of a partial-period tone moves, never the gain.
        #expect(abs(peak(conditioned) - peak(original)) < 0.01)
    }

    @Test func silenceIsLeftAloneSoItStillReadsAsSilence() {
        #expect(peak(SpeechAudioConditioning.condition([Float](repeating: 0, count: 16_000))) == 0)
        #expect(peak(SpeechAudioConditioning.condition(tone(peak: 0.001))) < 0.005)
    }

    @Test func aDCOffsetIsRemovedRatherThanAmplified() {
        let conditioned = SpeechAudioConditioning.condition(tone(peak: 0.1, offset: 0.2))
        let mean = conditioned.reduce(Float(0), +) / Float(conditioned.count)
        #expect(abs(mean) < 0.01)
    }

    @Test func anEmptyRecordingIsHandled() {
        #expect(SpeechAudioConditioning.condition([]).isEmpty)
    }

    /// The thump of the finger tapping Stop used to set the gain for the whole
    /// dictation: one sample at 0.9 and quiet speech stayed quiet.
    @Test func aClickDoesNotSetTheLevel() {
        var recording = tone(peak: 0.05, count: 48_000)
        for index in 30_000..<30_160 { recording[index] = index.isMultiple(of: 2) ? 0.9 : -0.9 }
        let conditioned = SpeechAudioConditioning.condition(recording)
        // The speech gets the full eight times, where the click allowed none.
        #expect(abs(peak(Array(conditioned[0..<29_000])) - 0.4) < 0.02)
    }

    @Test func nothingAmplifiedPassesFullScale() {
        // 0.85 / 0.15 is inside the gain ceiling, so the speech reaches target.
        var recording = tone(peak: 0.15, count: 48_000)
        for index in 30_000..<30_160 { recording[index] = 0.9 }
        let conditioned = SpeechAudioConditioning.condition(recording)
        #expect(peak(conditioned) <= 1)
        // Speech under the target is left exactly as the gain made it.
        #expect(abs(peak(Array(conditioned[0..<29_000])) - 0.85) < 0.02)
    }

    /// A click in an otherwise silent recording is not speech to be levelled.
    @Test func silenceWithAClickStaysSilent() {
        var recording = [Float](repeating: 0, count: 48_000)
        for index in 30_000..<30_160 { recording[index] = 0.5 }
        let conditioned = SpeechAudioConditioning.condition(recording)
        #expect(peak(conditioned) <= 0.51)
    }

    @Test func theLimiterIsContinuousAndBounded() {
        #expect(SpeechAudioConditioning.limited(0.5) == 0.5)
        #expect(SpeechAudioConditioning.limited(0.85) == 0.85)
        #expect(SpeechAudioConditioning.limited(0.86) > 0.85)
        #expect(SpeechAudioConditioning.limited(4) <= 1)
        #expect(SpeechAudioConditioning.limited(-4) >= -1)
    }

    /// A streaming chunk louder than everything before it used to be
    /// amplified past full scale.
    @Test func aLouderStreamingChunkIsLimited() {
        let chunk = tone(peak: 0.5, count: 3_200)
        #expect(peak(SpeechAudioConditioning.condition(chunk, peak: 0.1)) <= 1)
    }

    /// Three seconds of quiet speech and then five minutes of a recorder left
    /// running: the silence must not push the speech out of the level.
    @Test func briefSpeechInALongRecordingStillSetsTheLevel() {
        let recording = tone(peak: 0.05, count: 3 * 16_000) + [Float](repeating: 0, count: 300 * 16_000)
        let conditioned = SpeechAudioConditioning.condition(recording)
        #expect(abs(peak(Array(conditioned[0..<(3 * 16_000)])) - 0.4) < 0.02)
    }

    @Test func theSetAsideIsBounded() {
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 0) == 2)
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 250) == 5)
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 15_000) == 10)
    }
}
