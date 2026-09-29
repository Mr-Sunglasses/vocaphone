import Foundation

/// How many ONNX Runtime workers a sherpa recognizer gets.
///
/// One per performance core. An iPhone has two, beside four efficiency cores,
/// and the old rule — every core but two, at most four — handed the pool two
/// of each. ONNX Runtime splits an operator evenly across its workers and
/// waits for the slowest, so the two on efficiency cores set the pace for the
/// two that were not. It also left nothing for the capture pipeline, the voice
/// activity detector and the interface, which now run beside a decode made
/// while the user is still speaking.
enum SherpaThreads {
    static var count: Int {
        count(performanceCores: performanceCores, processorCount: ProcessInfo.processInfo.processorCount)
    }

    static func count(performanceCores: Int?, processorCount: Int) -> Int {
        guard let performanceCores, performanceCores > 0 else {
            // The previous rule, for a system that will not say.
            return max(2, min(processorCount - 2, 4))
        }
        return max(2, min(performanceCores, 4))
    }

    /// `hw.perflevel0.physicalcpu`: the performance cores, on Apple silicon.
    private static var performanceCores: Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("hw.perflevel0.physicalcpu", &value, &size, nil, 0) == 0 else { return nil }
        return Int(value)
    }
}
