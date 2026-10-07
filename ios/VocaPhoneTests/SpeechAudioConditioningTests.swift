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

    /// A second of speech in thirty seconds of room noise: the noise is sound
    /// in every frame, and must not push the speech out of the level.
    @Test func speechOverRoomNoiseStillSetsTheLevel() {
        var recording: [Float] = []
        recording.reserveCapacity(31 * 16_000)
        for index in 0..<(30 * 16_000) {
            let hiss = Float((index % 997) * 7_919 % 97 - 48) / 48
            recording.append(hiss * 0.01)
        }
        // Loud enough that the right level (0.3, a gain under 3) and the wrong
        // one (the noise, the full eight) come out differently.
        recording += tone(peak: 0.3, count: 16_000)
        let conditioned = SpeechAudioConditioning.condition(recording)
        let speech = Array(conditioned[(30 * 16_000)...])
        #expect(abs(peak(speech) - 0.85) < 0.03)
    }

    @Test func theSetAsideFollowsTheAudibleAudio() {
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 0) == 2)
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 10) == 5)
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 500) == 16)
        #expect(SpeechAudioConditioning.setAside(audibleFrames: 15_000) == 16)
    }

    /// A 300 ms fumble in ten seconds of speech: longer than a click, and still
    /// not the level.
    @Test func aLongerKnockInADictationDoesNotSetTheLevel() {
        var recording = tone(peak: 0.05, count: 10 * 16_000)
        for index in 100_000..<104_800 { recording[index] = index.isMultiple(of: 2) ? 0.9 : -0.9 }
        let conditioned = SpeechAudioConditioning.condition(recording)
        #expect(abs(peak(Array(conditioned[0..<99_000])) - 0.4) < 0.02)
    }

    // MARK: - Levelling kept across a growing dictation

    /// Kept levelling has to give back the very samples the earlier pass did,
    /// not merely close ones: the window cache trusts that the audio is the same.
    @Test func keptLevellingReproducesTheEarlierAudioExactly() {
        let first = tone(peak: 0.2, offset: 0.003, count: 32_000)
        let longer = first + tone(peak: 0.21, offset: 0.0032, count: 8_000)
        let early = SpeechAudioConditioning.levelled(first)
        let later = SpeechAudioConditioning.levelled(longer, keeping: (early.gain, early.offset))
        #expect(later.gain == early.gain)
        #expect(later.offset == early.offset)
        #expect(Array(later.samples.prefix(first.count)) == early.samples)
        // Left to itself the longer recording would have levelled differently.
        let own = SpeechAudioConditioning.levelled(longer)
        #expect(own.gain != early.gain || own.offset != early.offset)
    }

    /// A dictation that started quietly and went on at full voice is a
    /// different recording, and keeping the quiet start's boost would drive the
    /// rest of it into the limiter.
    @Test func aMuchLouderContinuationIsLevelledAfresh() {
        let first = tone(peak: 0.05, count: 32_000)
        let longer = first + tone(peak: 0.4, count: 32_000)
        let early = SpeechAudioConditioning.levelled(first)
        let later = SpeechAudioConditioning.levelled(longer, keeping: (early.gain, early.offset))
        #expect(later.gain == SpeechAudioConditioning.levelled(longer).gain)
        #expect(later.gain < early.gain)
    }

    @Test func aDifferentOffsetIsNotKept() {
        let samples = tone(peak: 0.2, offset: 0.01)
        let levelled = SpeechAudioConditioning.levelled(samples)
        let kept = SpeechAudioConditioning.levelled(samples, keeping: (levelled.gain, 0.0))
        #expect(kept.offset == levelled.offset)
    }
}
