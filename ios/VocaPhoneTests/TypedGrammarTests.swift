import Foundation
import Testing

/// `assets/grammar/typed_fixtures.json`, which `TypedGrammarTest.kt` reads too,
/// so the two keyboards decide the same things about the same text.
struct TypedGrammarTests {
    struct Document: Decodable {
        let region: [RegionCase]
        let fix: [FixCase]
        let edit: [EditCase]
        let stillDescribes: [DescribesCase]
    }

    struct RegionCase: Decodable {
        let name: String
        let before: String
        let startKnown: Bool
        let region: String?
    }

    struct ExpectedFix: Decodable {
        let corrected: String
        let start: Int
        let original: String
        let replacement: String
        let label: String
    }

    struct FixCase: Decodable {
        let name: String
        let checked: String
        let corrected: String
        let fix: ExpectedFix?
    }

    struct ExpectedEdit: Decodable {
        let deleteBefore: Int
        let insert: String
    }

    struct EditCase: Decodable {
        let name: String
        let checked: String
        let corrected: String
        let before: String
        let edit: ExpectedEdit?
    }

    struct DescribesCase: Decodable {
        let name: String
        let checked: String
        let corrected: String
        let window: String
        let expected: Bool
    }

    static let document: Document = try! JSONDecoder().decode(
        Document.self,
        from: Data(contentsOf: GrammarFixtures.root.appendingPathComponent("typed_fixtures.json"))
    )

    @Test(arguments: document.region.map(\.name))
    func region(_ name: String) {
        let test = Self.document.region.first { $0.name == name }!
        #expect(TypedGrammar.region(before: test.before, startKnown: test.startKnown) == test.region)
    }

    @Test(arguments: document.fix.map(\.name))
    func fix(_ name: String) throws {
        let test = Self.document.fix.first { $0.name == name }!
        let fix = TypedGrammar.fix(checked: test.checked, corrected: test.corrected)
        guard let expected = test.fix else {
            #expect(fix == nil)
            return
        }
        let found = try #require(fix)
        #expect(found.corrected == expected.corrected)
        #expect(found.start == expected.start)
        #expect(found.original == expected.original)
        #expect(found.replacement == expected.replacement)
        #expect(found.label == expected.label)
    }

    @Test(arguments: document.edit.map(\.name))
    func edit(_ name: String) throws {
        let test = Self.document.edit.first { $0.name == name }!
        let fix = try #require(TypedGrammar.fix(checked: test.checked, corrected: test.corrected))
        let edit = TypedGrammar.edit(fix, before: test.before)
        guard let expected = test.edit else {
            #expect(edit == nil)
            return
        }
        #expect(edit == TypedGrammar.Edit(deleteBefore: expected.deleteBefore, insert: expected.insert))
        // Played back the way the keyboard applies it: deletions, then the insert.
        let applied = try #require(edit)
        let after = String(test.before.dropLast(applied.deleteBefore)) + applied.insert
        let body = test.before.replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        let trailing = String(test.before.dropFirst(body.count))
        #expect(after == String(body.dropLast(fix.checked.count)) + fix.corrected + trailing)
    }

    @Test(arguments: document.stillDescribes.map(\.name))
    func stillDescribes(_ name: String) throws {
        let test = Self.document.stillDescribes.first { $0.name == name }!
        let fix = try #require(TypedGrammar.fix(checked: test.checked, corrected: test.corrected))
        #expect(TypedGrammar.stillDescribes(fix, window: test.window) == test.expected)
    }

    @Test func aSentenceLongerThanTheLimitIsNotChecked() {
        let long = String(repeating: "word ", count: TypedGrammar.maxRegion / 5 + 1)
            .trimmingCharacters(in: .whitespaces) + ". "
        #expect(TypedGrammar.region(before: long, startKnown: true) == nil)
    }

    @Test func aLongEarlierSentenceLeavesTheLastOneAloneToCheck() {
        let long = String(repeating: "word ", count: TypedGrammar.maxRegion / 5)
            .trimmingCharacters(in: .whitespaces) + "."
        #expect(TypedGrammar.region(before: "\(long) They was late. ", startKnown: true) == "They was late.")
    }

    @Test func wordsPresentMatchesWholeWordsIgnoringCaseAndApostropheStyle() {
        let keep = ["kubo", "don't", "ann", "zanele"]
        #expect(TypedGrammar.wordsPresent(keep, in: "Ask Kubo, he don\u{2019}t know Anna.") == ["kubo", "don't"])
    }

    /// The one place the ports count differently: an emoji is two UTF-16 units
    /// on Android and one `Character` here, which is what `deleteBackward()`
    /// removes. Only the text from the first change on is deleted, so it
    /// matters only when the emoji is inside that span.
    @Test func deletionsCountCharactersNotCodeUnits() throws {
        let fix = try #require(TypedGrammar.fix(checked: "They was late 😀.", corrected: "They were late 😀."))
        let edit = try #require(TypedGrammar.edit(fix, before: "They was late 😀. "))
        #expect(edit.deleteBefore == "was late 😀. ".count + 1)
        #expect(edit.insert == " were late 😀. ")
    }
}
