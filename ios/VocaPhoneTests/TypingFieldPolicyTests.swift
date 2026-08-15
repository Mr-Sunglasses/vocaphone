import Testing
import UIKit

/// The table of field traits that must switch typing intelligence **off** —
/// not merely hide the strip.
///
/// Hiding the strip while still consulting a spell checker would leave the
/// user's password flowing through a dictionary lookup, which is exactly what
/// the policy exists to prevent. iOS often swaps to the system keyboard for
/// secure fields, but "often" is not something to build a privacy claim on.
struct TypingFieldPolicyTests {
    @Test func anOrdinaryTextFieldIsAllowed() {
        let policy = TypingFieldPolicy.resolve(
            isSecureTextEntry: false,
            contentType: nil,
            keyboardType: .default
        )
        #expect(policy.allowsTypingIntelligence)
        #expect(policy.reason == nil)
    }

    @Test func secureEntryIsRefused() {
        let policy = TypingFieldPolicy.resolve(
            isSecureTextEntry: true,
            contentType: nil,
            keyboardType: .default
        )
        #expect(!policy.allowsTypingIntelligence)
        #expect(policy.reason == .secureEntry)
    }

    /// A one-time code is the clearest case: short, numeric, worth nothing to a
    /// spell checker and everything to whoever intercepts it.
    @Test func everySensitiveContentTypeIsRefused() {
        for contentType in TypingFieldPolicy.sensitiveContentTypes {
            let policy = TypingFieldPolicy.resolve(
                isSecureTextEntry: false,
                contentType: contentType,
                keyboardType: .default
            )
            #expect(
                !policy.allowsTypingIntelligence,
                "\(contentType.rawValue) must disable typing intelligence"
            )
            #expect(policy.reason == .sensitiveContentType)
        }
    }

    @Test func numberPadsAreRefused() {
        for keyboardType in TypingFieldPolicy.numericKeyboardTypes {
            let policy = TypingFieldPolicy.resolve(
                isSecureTextEntry: false,
                contentType: nil,
                keyboardType: keyboardType
            )
            #expect(!policy.allowsTypingIntelligence)
            #expect(policy.reason == .numericKeyboard)
        }
    }

    /// The content types a keyboard *should* help with, so the refusal list
    /// cannot quietly grow into "everything".
    @Test func ordinaryContentTypesStayAllowed() {
        for contentType in [
            UITextContentType.emailAddress, .name, .username, .URL, .fullStreetAddress,
        ] {
            let policy = TypingFieldPolicy.resolve(
                isSecureTextEntry: false,
                contentType: contentType,
                keyboardType: .default
            )
            #expect(
                policy.allowsTypingIntelligence,
                "\(contentType.rawValue) should still get suggestions"
            )
        }
    }

    /// Secure entry wins over anything else the field says.
    @Test func secureEntryOutranksAnAllowedContentType() {
        let policy = TypingFieldPolicy.resolve(
            isSecureTextEntry: true,
            contentType: .username,
            keyboardType: .default
        )
        #expect(!policy.allowsTypingIntelligence)
    }
}

/// Typing language is not dictation language. Someone dictating in Hindi still
/// types on an English QWERTY layout, and correcting their English against a
/// Hindi dictionary would be nonsense.
struct TypingLanguageTests {
    private let available = ["en_US", "en_GB", "fr_FR", "de_DE"]

    @Test func anExactMatchWins() {
        #expect(TypingLanguage.resolve(preferred: ["fr_FR"], available: available) == "fr_FR")
    }

    /// A user set to `en_IN` should get an English dictionary, not nothing.
    @Test func aRegionWithoutDataFallsBackToItsLanguage() {
        let resolved = TypingLanguage.resolve(preferred: ["en-IN"], available: available)
        #expect(resolved.hasPrefix("en"))
    }

    @Test func theFirstSupportedPreferenceWins() {
        #expect(
            TypingLanguage.resolve(preferred: ["ja-JP", "de-DE"], available: available) == "de_DE"
        )
    }

    @Test func nothingSupportedFallsBackToEnglish() {
        #expect(TypingLanguage.resolve(preferred: ["ja-JP"], available: available) == "en_US")
        #expect(TypingLanguage.resolve(preferred: [], available: []) == TypingLanguage.fallback)
    }
}
