import Testing

struct TranscriptionQualityTests {
    @Test func whisperRetriesAreBoundedToThePromisedNumber() {
        #expect(TranscriptionQuality.fast.whisperRetryCount == 0)
        #expect(TranscriptionQuality.balanced.whisperRetryCount == 1)
        #expect(TranscriptionQuality.accurate.whisperRetryCount == 2)
    }
}
