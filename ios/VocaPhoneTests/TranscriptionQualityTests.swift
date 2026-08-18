import Testing

struct TranscriptionQualityTests {
    @Test func whisperFallbackIsBoundedToThePromisedNumberOfRetries() {
        #expect(TranscriptionQuality.fast.whisperKitTemperatureFallbackCount == 0)
        #expect(TranscriptionQuality.balanced.whisperKitTemperatureFallbackCount == 1)
        #expect(TranscriptionQuality.accurate.whisperKitTemperatureFallbackCount == 2)

        #expect(TranscriptionQuality.fast.whisperKitTemperatureIncrement == 0)
        #expect(TranscriptionQuality.balanced.whisperKitTemperatureIncrement == 1)
        #expect(TranscriptionQuality.accurate.whisperKitTemperatureIncrement == 0.5)
    }
}
