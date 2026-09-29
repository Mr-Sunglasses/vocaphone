import Foundation
import Testing

/// The product is written "vocaphone" wherever a person can read or hear it
/// (see `app-design-standard.md`, "Preserve approved product casing"). About
/// a dozen strings had drifted to "VocaPhone" — the stats share text, the
/// Quick Dictation screens, the keyboard's VoiceOver labels — so this reads
/// the source for string literals that spell it the other way.
///
/// Identifiers that merely start with the name (`VocaPhoneLogo`,
/// `VocaPhoneAppGroup`) are not the word and do not match; comments are not
/// read by anyone using the app and are skipped.
struct ProductNameTests {
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static let targets = [
        "VocaPhoneApp", "VocaPhoneKeyboard", "VocaPhoneLiveActivity", "VocaPhoneShared",
    ]

    /// Places where the capitalised spelling is the subject, not the brand:
    /// custom-vocabulary correction is demonstrated on a camel-cased word.
    private static let allowed: Set<String> = ["VocabularyCorrection.swift"]

    @Test func userFacingStringsSpellTheProductInLowercase() throws {
        let literal = try NSRegularExpression(pattern: #""[^"\n]*\bVocaPhone\b[^"\n]*""#)
        var offenders: [String] = []
        var scanned = 0
        for target in Self.targets {
            let directory = Self.root.appendingPathComponent(target)
            let files = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
            while let file = files?.nextObject() as? URL {
                guard file.pathExtension == "swift",
                      !Self.allowed.contains(file.lastPathComponent)
                else { continue }
                scanned += 1
                let lines = try String(contentsOf: file, encoding: .utf8)
                    .components(separatedBy: "\n")
                for (index, line) in lines.enumerated() {
                    let code = line.trimmingCharacters(in: .whitespaces)
                    if code.hasPrefix("//") { continue }
                    let range = NSRange(code.startIndex..., in: code)
                    if literal.firstMatch(in: code, range: range) != nil {
                        offenders.append("\(target)/…/\(file.lastPathComponent):\(index + 1)")
                    }
                }
            }
        }
        // A wrong path would find nothing and pass; the app has well over this.
        #expect(scanned > 100, "Scanned only \(scanned) files under \(Self.root.path)")
        #expect(offenders.isEmpty, "Write “vocaphone”: \(offenders)")
    }
}
