import AVFAudio
import Foundation

enum RecordingSoundCue: Sendable {
    case start
    case stop

    fileprivate var frequency: Double {
        switch self {
        case .start: 880
        case .stop: 620
        }
    }
}

/// Plays a very short cue while the microphone graph is warm but before or
/// after capture. Keeping the cue outside the capture window prevents the
/// phone's own speaker from becoming the first or last sound in a transcript.
@MainActor
final class RecordingSoundFeedback {
    private var player: AVAudioPlayer?

    func play(_ cue: RecordingSoundCue) async {
        guard KeyboardPreferences.recordingSoundsEnabled else { return }
        do {
            let player = try AVAudioPlayer(data: Self.waveData(frequency: cue.frequency))
            self.player = player
            player.volume = 0.28
            player.prepareToPlay()
            guard player.play() else { return }
            try? await Task.sleep(for: .milliseconds(140))
            if Task.isCancelled { player.stop() }
            if self.player === player { self.player = nil }
        } catch {
            // Sound feedback is optional and must never block dictation.
        }
    }

    private static func waveData(frequency: Double) -> Data {
        let sampleRate: UInt32 = 44_100
        let duration = 0.075
        let sampleCount = Int(Double(sampleRate) * duration)
        let bytesPerSample = 2
        let dataSize = UInt32(sampleCount * bytesPerSample)
        var data = Data()

        data.append(contentsOf: "RIFF".utf8)
        data.appendLittleEndian(UInt32(36) + dataSize)
        data.append(contentsOf: "WAVEfmt ".utf8)
        data.appendLittleEndian(UInt32(16))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(UInt16(1))
        data.appendLittleEndian(sampleRate)
        data.appendLittleEndian(sampleRate * UInt32(bytesPerSample))
        data.appendLittleEndian(UInt16(bytesPerSample))
        data.appendLittleEndian(UInt16(16))
        data.append(contentsOf: "data".utf8)
        data.appendLittleEndian(dataSize)

        let fadeSamples = max(1, Int(Double(sampleRate) * 0.008))
        for index in 0..<sampleCount {
            let fadeIn = min(1, Double(index) / Double(fadeSamples))
            let fadeOut = min(1, Double(sampleCount - index - 1) / Double(fadeSamples))
            let envelope = min(fadeIn, fadeOut)
            let phase = 2 * Double.pi * frequency * Double(index) / Double(sampleRate)
            let sample = Int16((sin(phase) * envelope * 0.28 * Double(Int16.max)).rounded())
            data.appendLittleEndian(UInt16(bitPattern: sample))
        }
        return data
    }
}

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var littleEndian = value.littleEndian
        Swift.withUnsafeBytes(of: &littleEndian) { append(contentsOf: $0) }
    }
}
