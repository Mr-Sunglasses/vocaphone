import Foundation

/// Speech models resample to 16 kHz internally, so converting once at capture
/// removes a six-fold overhead from every byte that follows: the file on disk,
/// the WebSocket payload, and the fallback upload.
enum CaptureFormat {
    static let sampleRate: Double = 16_000
    /// Roughly 100 ms of audio per chunk. Small enough to keep streaming
    /// latency low, large enough to avoid a WebSocket frame every drain tick.
    static let chunkSampleCount = 1_600
    /// A recording whose loudest sample never reached this is digital silence,
    /// which is what a microphone another app has taken delivers. A working
    /// microphone in a quiet room still has a noise floor far above two
    /// sixteen-bit least-significant bits.
    static let silenceThreshold: Float = 2 / 32_768
}
