import Foundation
import Testing

/// The real model through the real ONNX Runtime, against the reference
/// recipe's outputs. Opt-in, because it needs the 28 MB download:
///
///     just ios grammar-model-test
///
/// which fetches the pinned files and passes their folder as
/// `VOCA_GRAMMAR_MODEL_DIR`.
struct GrammarModelEndToEndTests {
    private static let directory = ProcessInfo.processInfo.environment["VOCA_GRAMMAR_MODEL_DIR"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }

    @Test(.enabled(if: directory != nil, "set VOCA_GRAMMAR_MODEL_DIR (just ios grammar-model-test)"))
    func theRealModelReproducesTheReferenceOutputs() throws {
        let loaded = try GrammarCorrector.loadFrom(Self.directory!)
        defer { loaded.close() }
        var timings: [Double] = []
        var mismatches: [String] = []
        for fixture in GrammarFixtures.document.cases {
            let start = DispatchTime.now().uptimeNanoseconds
            let output = try loaded.tagger.correct(fixture.input, vocabulary: Set(fixture.vocabulary))
            timings.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
            if output != fixture.output { mismatches.append("“\(fixture.input)” → “\(output)”, expected “\(fixture.output)”") }
        }
        timings.sort()
        print("grammar e2e: median \(timings[timings.count / 2]) ms, max \(timings.last!) ms")
        #expect(mismatches.isEmpty, "\(mismatches.joined(separator: "\n"))")
    }
}
