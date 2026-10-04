import Foundation
import Testing

/// The out-of-the-box keyboard. A switch that should start on has to read on
/// both in Settings and in the keyboard, before anyone has touched it.
@MainActor
struct KeyboardDefaultsTests {
    @Test func typingAndDictationSwitchesStartOn() {
        #expect(KeyboardDefaults.typingSuggestions)
        #expect(KeyboardDefaults.autocorrect)
        #expect(KeyboardDefaults.nextWordPrediction)
        #expect(KeyboardDefaults.learnAsIType)
        #expect(KeyboardDefaults.smartPunctuation)
        #expect(KeyboardDefaults.emojiSuggestions)
        #expect(KeyboardDefaults.swipeTyping)
        #expect(KeyboardDefaults.spacebarCursor)
        #expect(KeyboardDefaults.numbersAsDigits)
        #expect(KeyboardDefaults.spokenEmoji)
        #expect(KeyboardDefaults.repairSpeech)
        // The exceptions. A buzz on every key is off, as the system
        // keyboard's own Haptic switch ships off; and a preview the finished
        // text can differ from is asked for, not assumed.
        #expect(!KeyboardDefaults.typingHaptics)
        #expect(!KeyboardDefaults.liveWords)
    }

    /// A key nobody has written reads as the default, which is what a fresh
    /// install sees — and what a keyboard without Full Access always sees.
    @Test func anUnsetPreferenceReadsAsItsDefault() {
        let keys = [
            KeyboardPreferences.typingSuggestionsKey,
            KeyboardPreferences.typingHapticsKey,
            KeyboardPreferences.swipeTypingKey,
            KeyboardPreferences.numbersAsDigitsKey,
            KeyboardPreferences.spokenEmojiKey,
            KeyboardPreferences.liveWordsKey,
        ]
        let store = KeyboardPreferences.defaults
        let saved = keys.map { store?.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { store?.set(value, forKey: key) } else { store?.removeObject(forKey: key) }
            }
        }
        keys.forEach { store?.removeObject(forKey: $0) }

        #expect(KeyboardPreferences.typingSuggestionsEnabled == KeyboardDefaults.typingSuggestions)
        #expect(KeyboardPreferences.typingHapticsEnabled == KeyboardDefaults.typingHaptics)
        #expect(KeyboardPreferences.swipeTypingEnabled == KeyboardDefaults.swipeTyping)
        #expect(KeyboardPreferences.numbersAsDigits == KeyboardDefaults.numbersAsDigits)
        #expect(KeyboardPreferences.spokenEmoji == KeyboardDefaults.spokenEmoji)
        #expect(KeyboardPreferences.liveWords == KeyboardDefaults.liveWords)
    }
}
