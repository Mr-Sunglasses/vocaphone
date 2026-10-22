import Foundation

/// One ONNX Runtime session over `mindtype_tagger.onnx`, through the C bridge
/// in `GrammarOnnxBridge.c`.
///
/// The runtime is the copy sherpa-onnx already links into the app; nothing
/// here may be reached from the keyboard extension, which has neither the
/// runtime nor the memory for a 27 MB graph.
final class GrammarSession: @unchecked Sendable {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private let lock = NSLock()
    private var handle: VocaPhoneGrammarSession?
    private var output: [Float] = []

    init(model: URL, threads: Int32 = 2) throws {
        var error = [CChar](repeating: 0, count: 512)
        guard let handle = VocaPhoneGrammarCreate(model.path, threads, &error, Int32(error.count)) else {
            throw Failure(description: String(cString: error))
        }
        self.handle = handle
    }

    deinit { close() }

    func run(ids: [Int64], rows: [Int32]) throws -> [[Float]] {
        try lock.withLock {
            guard let handle else { throw Failure(description: "grammar session is closed") }
            let capacity = rows.count * GrammarTagger.labelCount
            if output.count < capacity { output = [Float](repeating: 0, count: capacity) }
            var error = [CChar](repeating: 0, count: 512)
            let width = ids.withUnsafeBufferPointer { ids in
                rows.withUnsafeBufferPointer { rows in
                    output.withUnsafeMutableBufferPointer { output in
                        VocaPhoneGrammarRun(
                            handle, ids.baseAddress, Int32(ids.count), rows.baseAddress, Int32(rows.count),
                            output.baseAddress, Int64(output.count), &error, Int32(error.count)
                        )
                    }
                }
            }
            guard width > 0 else { throw Failure(description: String(cString: error)) }
            let w = Int(width)
            return (0..<rows.count).map { Array(output[($0 * w)..<(($0 + 1) * w)]) }
        }
    }

    func close() {
        lock.withLock {
            if let handle { VocaPhoneGrammarRelease(handle) }
            handle = nil
        }
    }
}
