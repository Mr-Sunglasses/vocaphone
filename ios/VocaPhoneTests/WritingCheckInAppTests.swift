import Foundation
import Testing

/// The Writing check screen's two decisions: whether to check, and when to
/// stop. As WritingCheckScreenTest.kt.
struct WritingCheckInAppTests {
    static let checker = WritingCheck(rules: WritingCheckTests.rules)
    static let english: Set<String> = {
        let url = WritingCheckTests.root.appendingPathComponent("keyboard/en.txt")
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        return Set(text.split(whereSeparator: \.isNewline).map { $0.lowercased() })
    }()

    static func applies(_ text: String) -> Bool {
        WritingCheck.applies(to: text, isDictionaryWord: english.contains)
    }

    /// Counts model calls from inside a detached task.
    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var value: Int { lock.withLock { count } }
        func add() { lock.withLock { count += 1 } }
    }

    @Test func frenchIsNotChecked() {
        let french = "Je sais dont il parle."
        // The English rules would offer "don't" here: the language test is
        // what keeps the screen from suggesting it.
        #expect(Self.checker.check(french).suggestions.contains { $0.shownReplacement == "don't" })
        #expect(!Self.applies(french))
        #expect(!Self.applies("C'est le livre dont elle parle."))
    }

    @Test func englishIsChecked() {
        #expect(!Self.english.isEmpty)
        #expect(Self.applies("I dont think this is the right way to do it."))
        #expect(Self.applies("dont worry"))
    }

    @Test func textWithoutLettersIsNotChecked() {
        #expect(!Self.applies("12 + 30 = 42"))
    }

    @Test func cancellingStopsAskingTheModel() async {
        let calls = Counter()
        let report = await Task.detached {
            await Self.checker.checkUntilCancelled(
                "The first sentence is here. The second one follows. A third comes last.",
                model: { sentence in
                    calls.add()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return sentence
                },
                options: WritingCheck.Options()
            )
        }.value
        #expect(report == nil)
        #expect(calls.value == 1)
    }

    @Test func cancellingWhileTheModelLoadsSkipsTheRetry() async {
        let calls = Counter()
        let report = await Task.detached {
            await Self.checker.checkUntilCancelled(
                "One short sentence.",
                model: { _ in
                    calls.add()
                    withUnsafeCurrentTask { $0?.cancel() }
                    return nil
                },
                options: WritingCheck.Options(),
                retryAfter: .seconds(60)
            )
        }.value
        #expect(report == nil)
        #expect(calls.value == 1)
    }

    @Test func aModelStillLoadingIsAskedOnceMore() async {
        let calls = Counter()
        let report = await Self.checker.checkUntilCancelled(
            "One short sentence.",
            model: { _ in
                calls.add()
                return nil
            },
            options: WritingCheck.Options(),
            retryAfter: .milliseconds(1)
        )
        #expect(report?.modelPending == true)
        #expect(calls.value == 2)
    }
}
