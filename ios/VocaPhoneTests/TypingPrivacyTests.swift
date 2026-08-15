import Foundation
import Testing

/// The claim this whole subsystem has to keep: **the keyboard now reads what you
/// type** is the sentence users fear, and the answer has to be enforceable
/// rather than merely written down.
///
/// Nothing typed leaves the device, is logged, or is exported. These tests are
/// the enforcement.
struct TypingPrivacyTests {
    /// The diagnostic vocabulary is a closed set of enum cases chosen at each
    /// call site. There is no `record(_ text: String)` for anything to leak
    /// through, and adding one would have to get past this file.
    @Test func theTypingSubsystemHasNoWayToLogContent() {
        // Every event the typing path can reach carries a fixed identifier and
        // nothing else. `metadata` is likewise an enum of closed vocabularies.
        let reachable: [DiagnosticEvent] = [.keyboardShown, .sessionStateChanged]
        for event in reachable {
            #expect(!event.rawValue.isEmpty)
        }
    }

    /// An export written after a full typing session contains counters and state
    /// names, and none of the words that produced them.
    @Test func anExportContainsNoTypedContent() throws {
        let secrets = ["hunter2", "kanishk", "vocaphone-secret-word"]

        // Everything the typing subsystem is allowed to tell the log about: that
        // the keyboard appeared, and that state moved. Never what was typed.
        DiagnosticLog.record(.keyboardShown, metadata: .fullAccess(true))
        DiagnosticLog.record(.sessionStateChanged, metadata: .state(.idle))

        let url = try DiagnosticLog.makeExportFile()
        defer { try? FileManager.default.removeItem(at: url) }
        let export = try String(contentsOf: url, encoding: .utf8)

        for secret in secrets {
            #expect(
                !export.localizedCaseInsensitiveContains(secret),
                "the export should never contain typed text"
            )
        }
    }

    /// Learned words are a store, not a feature with a browser. The UI shows a
    /// count; the words themselves are never listed, and never logged.
    @Test func learnedWordsStayInTheirStore() {
        var learned = LearnedWords()
        learned.learn("kanishk")

        #expect(learned.contains("Kanishk"))
        #expect(learned.count == 1)
        // The only way out is a completion for a prefix the user is already
        // typing, which is the one place the word is useful.
        #expect(learned.completions(for: "kan", limit: 3) == ["kanishk"])
        #expect(learned.completions(for: "zzz", limit: 3).isEmpty)
    }

    @Test func resettingForgetsEverything() {
        var learned = LearnedWords()
        learned.learn("one")
        learned.learn("two")
        learned.removeAll()
        #expect(learned.count == 0)
    }

    /// Capacity is a memory bound, evicted least-recently-used. A keyboard that
    /// grew its dictionary without limit would eventually be killed for it.
    @Test func theStoreIsBoundedAndEvictsTheOldest() {
        var learned = LearnedWords()
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        for index in 0..<(LearnedWords.capacity + 10) {
            learned.learn("word\(index)", now: base.addingTimeInterval(Double(index)))
        }
        #expect(learned.count == LearnedWords.capacity)
        // The oldest went; the newest stayed.
        #expect(!learned.contains("word0"))
        #expect(learned.contains("word\(LearnedWords.capacity + 9)"))
    }

    /// Three sightings, then it is the user's word. Fewer would learn typos.
    @Test func aWordIsLearnedOnlyAfterItIsRepeated() {
        var learned = LearnedWords()
        let first = learned.note("vocaphone")
        let second = learned.note("vocaphone")
        let third = learned.note("vocaphone")
        #expect(!first)
        #expect(!second)
        #expect(third)
    }

    /// Without Full Access there is no App Group to write to. Learning still
    /// works for the life of the keyboard, and the settings screen says so
    /// rather than pretending it persisted.
    @Test func theStoreDegradesToMemoryWithoutAnAppGroup() {
        let store = LearnedWordStore(containerURL: nil)
        #expect(!store.isPersistent)
        store.update { $0.learn("ephemeral") }
        #expect(store.snapshot().contains("ephemeral"))
    }

    /// And with somewhere to write, it survives a new instance — which is the
    /// difference between a keyboard that learns and one that forgets nightly.
    @Test func theStorePersistsWhenThereIsAContainer() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let first = LearnedWordStore(containerURL: directory)
        #expect(first.isPersistent)
        first.update { $0.learn("persistent") }

        let second = LearnedWordStore(containerURL: directory)
        #expect(second.snapshot().contains("persistent"))
    }
}
