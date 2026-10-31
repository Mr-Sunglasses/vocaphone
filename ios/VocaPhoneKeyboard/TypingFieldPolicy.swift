import UIKit

/// Whether typing intelligence may run in this field at all.
///
/// Suggestions read what the user typed. In a password, one-time-code, PIN or
/// card-number field they must not run — no completion, no correction, no
/// next-word, and above all no learning. iOS *often* swaps to the system
/// keyboard for secure fields, but "often" is not something to build a privacy
/// claim on, so the keyboard decides for itself.
///
/// Disabled means disabled: the strip hides, and the subsystem is not consulted.
/// Hiding the strip while still computing candidates would leave the typed text
/// flowing through a spell checker in a password field, which is exactly the
/// thing this type exists to prevent.
///
/// Resolved from raw trait values rather than from a proxy, so the whole table
/// of combinations can be tested without a text document.
struct TypingFieldPolicy: Equatable {
    let allowsTypingIntelligence: Bool
    /// Why it was refused, for the one place it is worth saying out loud: a
    /// test failure.
    let reason: Reason?

    enum Reason: Equatable {
        case secureEntry
        case sensitiveContentType
        case numericKeyboard
    }

    static let allowed = TypingFieldPolicy(allowsTypingIntelligence: true, reason: nil)

    /// Content types that carry a secret even when the field is not marked
    /// secure. A one-time code is the clearest case: it is short, numeric, and
    /// worth nothing to a spell checker but everything to whoever intercepts it.
    static let sensitiveContentTypes: Set<UITextContentType> = [
        .password, .newPassword, .oneTimeCode, .creditCardNumber,
    ]

    /// Number pads carry PINs, card numbers and phone numbers, and there is
    /// nothing for a word-level suggestion to do on any of them.
    static let numericKeyboardTypes: Set<UIKeyboardType> = [
        .numberPad, .phonePad, .decimalPad, .asciiCapableNumberPad,
    ]

    static func resolve(
        isSecureTextEntry: Bool,
        contentType: UITextContentType?,
        keyboardType: UIKeyboardType
    ) -> TypingFieldPolicy {
        if isSecureTextEntry {
            return TypingFieldPolicy(allowsTypingIntelligence: false, reason: .secureEntry)
        }
        if let contentType, sensitiveContentTypes.contains(contentType) {
            return TypingFieldPolicy(
                allowsTypingIntelligence: false,
                reason: .sensitiveContentType
            )
        }
        if numericKeyboardTypes.contains(keyboardType) {
            return TypingFieldPolicy(allowsTypingIntelligence: false, reason: .numericKeyboard)
        }
        return .allowed
    }

    /// The same decision, read from a live document proxy.
    /// Whether "Check grammar while typing" may read this field: prose only.
    /// Not an address, a link, a search, a name or a field that turned
    /// autocorrection off — the app knows its field better than a grammar
    /// model does. On top of ``allowsTypingIntelligence``, never instead of it.
    static func allowsGrammarCheck(
        keyboardType: UIKeyboardType,
        contentType: UITextContentType?,
        autocorrectionType: UITextAutocorrectionType
    ) -> Bool {
        if autocorrectionType == .no { return false }
        if nonProseKeyboardTypes.contains(keyboardType) { return false }
        if let contentType, nonProseContentTypes.contains(contentType) { return false }
        return true
    }

    static let nonProseKeyboardTypes: Set<UIKeyboardType> = [
        .URL, .emailAddress, .webSearch, .namePhonePad, .numbersAndPunctuation,
    ]

    static let nonProseContentTypes: Set<UITextContentType> = [
        .URL, .emailAddress, .username, .name, .givenName, .middleName, .familyName,
        .nickname, .namePrefix, .nameSuffix, .organizationName, .jobTitle,
        .fullStreetAddress, .streetAddressLine1, .streetAddressLine2, .addressCity,
        .addressState, .addressCityAndState, .sublocality, .countryName, .postalCode,
        .telephoneNumber, .location,
    ]

    @MainActor
    static func allowsGrammarCheck(for proxy: UITextDocumentProxy) -> Bool {
        allowsGrammarCheck(
            keyboardType: proxy.keyboardType ?? .default,
            contentType: proxy.textContentType,
            autocorrectionType: proxy.autocorrectionType ?? .default
        )
    }

    /// Whether the Writing check button may offer to read this field: prose,
    /// as above, but a field that turned autocorrection off still gets the
    /// button. Many chat apps do, and tapping the button is the user asking.
    @MainActor
    static func allowsWritingCheck(for proxy: UITextDocumentProxy) -> Bool {
        allowsGrammarCheck(
            keyboardType: proxy.keyboardType ?? .default,
            contentType: proxy.textContentType,
            autocorrectionType: .default
        )
    }

    @MainActor
    static func resolve(for proxy: UITextDocumentProxy) -> TypingFieldPolicy {
        resolve(
            // `isSecureTextEntry` is not on `UITextDocumentProxy` in every
            // release, so it is read through the trait protocol the proxy
            // conforms to, defaulting to the safe answer when absent.
            isSecureTextEntry: (proxy as UITextInputTraits).isSecureTextEntry ?? false,
            contentType: proxy.textContentType,
            keyboardType: proxy.keyboardType ?? .default
        )
    }
}

/// The language typing intelligence corrects against.
///
/// Deliberately *not* `KeyboardPreferences.transcriptionLanguage`: that one
/// describes speech. Someone dictating in Hindi still types on an English
/// QWERTY layout, and correcting their English against a Hindi dictionary would
/// be nonsense. The layout decides the language, and the layout is English —
/// so this resolves from the user's own preferred locales, and is structured so
/// that adding a layout later adds a language for free.
enum TypingLanguage {
    static let fallback = "en_US"

    /// The first preferred locale the checker actually has data for.
    ///
    /// Matched on the language subtag rather than the whole identifier, because
    /// a user set to `en_IN` should get `en_GB` or `en_US` rather than nothing.
    static func resolve(preferred: [String], available: [String]) -> String {
        guard !available.isEmpty else { return fallback }
        for identifier in preferred {
            if available.contains(identifier) { return identifier }
            let subtag = languageSubtag(identifier)
            if let match = available.first(where: { languageSubtag($0) == subtag }) {
                return match
            }
        }
        return available.contains(fallback) ? fallback : (available.first ?? fallback)
    }

    private static func languageSubtag(_ identifier: String) -> String {
        identifier.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)
            ?? identifier
    }
}
