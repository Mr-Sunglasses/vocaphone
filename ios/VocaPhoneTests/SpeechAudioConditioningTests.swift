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
}
