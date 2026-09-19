import Testing
import UIKit

struct SmartPunctuationTests {
    private let all = SmartPunctuation.Traits.all

    @Test func quotesOpenAndCloseFromWhatPrecedesThem() {
        #expect(
            SmartPunctuation.substitution(for: "\"", before: "he said ", traits: all)?.insertion
                == SmartPunctuation.leftDoubleQuote
        )
        #expect(
            SmartPunctuation.substitution(for: "\"", before: "he said “yes", traits: all)?.insertion
                == SmartPunctuation.rightDoubleQuote
        )
        #expect(
            SmartPunctuation.substitution(for: "'", before: "", traits: all)?.insertion
                == SmartPunctuation.leftSingleQuote
        )
    }

    /// The apostrophe in "don't" is a closing quote, and getting it right is the
    /// whole reason curly quotes exist.
    @Test func anApostropheInsideAWordCloses() {
        #expect(
            SmartPunctuation.substitution(for: "'", before: "don", traits: all)?.insertion
                == SmartPunctuation.rightSingleQuote
        )
    }

    @Test func dashesAndEllipsesCollapse() {
        let dash = SmartPunctuation.substitution(for: "-", before: "wait-", traits: all)
        #expect(dash == SmartPunctuation.Substitution(deletions: 1, insertion: "—"))

        let ellipsis = SmartPunctuation.substitution(for: ".", before: "well..", traits: all)
        #expect(ellipsis == SmartPunctuation.Substitution(deletions: 2, insertion: "…"))

        // A third dash is a deliberate rule, not a longer dash.
        #expect(SmartPunctuation.substitution(for: "-", before: "wait--", traits: all) == nil)
    }

    /// A field that turns smart quotes off did so deliberately — a code editor
    /// does it precisely so a keyboard does not curl them into something that
    /// will not compile.
    @Test func theFieldCanRefuseEachSubstitution() {
        let noQuotes = SmartPunctuation.Traits(allowsQuotes: false, allowsDashes: true)
        #expect(SmartPunctuation.substitution(for: "\"", before: "", traits: noQuotes) == nil)
        #expect(SmartPunctuation.substitution(for: "-", before: "a-", traits: noQuotes) != nil)

        #expect(SmartPunctuation.substitution(for: "\"", before: "", traits: .none) == nil)
        #expect(SmartPunctuation.substitution(for: "-", before: "a-", traits: .none) == nil)
    }

    /// Curling a quote inside a path or a URL turns working text into text that
    /// looks right and no longer works.
    @Test func codeAndPathsAreLeftExactlyAsTyped() {
        for context in ["src/main", "user@host", "snake_case", "https://x.com", "a<b"] {
            #expect(
                SmartPunctuation.substitution(for: "'", before: context, traits: all) == nil,
                "\(context) should not be curled"
            )
        }
        // …but ordinary prose containing a slash earlier is still prose.
        #expect(SmartPunctuation.substitution(for: "'", before: "and/or then it", traits: all) != nil)
    }

    @Test func ordinaryCharactersAreNeverSubstituted() {
        #expect(SmartPunctuation.substitution(for: "a", before: "", traits: all) == nil)
        #expect(SmartPunctuation.substitution(for: ",", before: "hello", traits: all) == nil)
    }
}

/// Sentence capitalization that knows an abbreviation from a full stop. Each of
/// these is a small annoyance that arrives several times a day.
struct SentenceBoundaryTests {
    @Test func aRealFullStopEndsASentence() {
        #expect(SentenceBoundary.endsSentence("That is done. "))
        #expect(SentenceBoundary.endsSentence("Really! "))
        #expect(SentenceBoundary.endsSentence("Who? "))
        #expect(SentenceBoundary.endsSentence(""))
        #expect(SentenceBoundary.endsSentence("A line\n"))
    }

    @Test func abbreviationsDoNotEndASentence() {
        for abbreviation in ["e.g. ", "Mr. ", "vs. ", "etc. ", "i.e. ", "Dr. "] {
            #expect(
                !SentenceBoundary.endsSentence("see \(abbreviation)"),
                "\(abbreviation) should not capitalize the next word"
            )
        }
    }

    @Test func aNumberedListItemDoesNotEndASentence() {
        #expect(!SentenceBoundary.endsSentence("3. "))
        #expect(!SentenceBoundary.endsSentence("first\n12. "))
    }

    @Test func midSentenceIsNotASentenceStart() {
        #expect(!SentenceBoundary.endsSentence("hello "))
        #expect(!SentenceBoundary.endsSentence("hello"))
    }
}

struct SymbolAlternativesTests {
    /// Without these, the only way to type "€" is to leave vocaphone.
    @Test func symbolsOfferTheAlternatesPeopleHuntFor() {
        #expect(KeyAlternatives.options(for: "$", shift: .off).contains("€"))
        #expect(KeyAlternatives.options(for: "-", shift: .off).contains("—"))
        #expect(KeyAlternatives.options(for: "?", shift: .off).contains("¿"))
        // The base always leads, so lifting without moving types the key itself.
        #expect(KeyAlternatives.options(for: "$", shift: .off).first == "$")
    }

    /// Symbols have no case, so Shift must not turn "€" into anything else.
    @Test func shiftDoesNotChangeSymbols() {
        #expect(
            KeyAlternatives.options(for: "$", shift: .locked)
                == KeyAlternatives.options(for: "$", shift: .off)
        )
    }

    @Test func domainsAppearOnlyInFieldsThatWantThem() {
        #expect(KeyAlternatives.options(for: ".", shift: .off, keyboardType: .URL).contains(".com"))
        #expect(
            KeyAlternatives.options(for: ".", shift: .off, keyboardType: .emailAddress)
                .contains(".org")
        )
        let plain = KeyAlternatives.options(for: ".", shift: .off, keyboardType: .default)
        #expect(!plain.contains(".com"))
        // In ordinary prose a full stop still offers the ellipsis.
        #expect(plain.contains("…"))
    }
}

/// The shift key's third answer.
///
/// `UITextDocumentProxy` returns `nil` for its context whenever the host has not
/// answered. Reading that as an empty document meant "start of a sentence", so
/// Shift came on — on whichever keystroke the host happened to skip, which is
/// how a capital letter turned up in the middle of a word.
struct AutomaticShiftTests {
    /// The bug, stated directly: mid-sentence, an unanswered read must change
    /// nothing.
    @Test func anUnansweredContextLeavesTheShiftKeyAlone() {
        #expect(
            AutomaticShift.state(
                documentBefore: nil,
                autocapitalization: .sentences,
                current: .off
            ) == nil
        )
        #expect(
            AutomaticShift.state(
                documentBefore: nil,
                autocapitalization: .words,
                current: .off
            ) == nil
        )
    }

    /// A genuinely empty document really is the start of a sentence, and that
    /// behaviour has to survive the fix.
    @Test func anEmptyDocumentStillStartsASentence() {
        #expect(
            AutomaticShift.state(
                documentBefore: "",
                autocapitalization: .sentences,
                current: .off
            ) == .on
        )
    }

    /// The reported case: typing on through a sentence stays lowercase.
    @Test func typingThroughASentenceStaysLowercase() {
        for before in ["how ", "how are ", "I am the ", "hello wor"] {
            #expect(
                AutomaticShift.state(
                    documentBefore: before,
                    autocapitalization: .sentences,
                    current: .off
                ) == .off,
                "\(before) should not capitalise the next letter"
            )
        }
    }

    @Test func aSentenceEndStillCapitalises() {
        #expect(
            AutomaticShift.state(
                documentBefore: "Done. ",
                autocapitalization: .sentences,
                current: .off
            ) == .on
        )
        // Abbreviations are not sentence ends, which `SentenceBoundary` owns.
        #expect(
            AutomaticShift.state(
                documentBefore: "Mr. ",
                autocapitalization: .sentences,
                current: .off
            ) == .off
        )
    }

    /// A word-capitalising field still capitalises every word, and a field that
    /// asked for none still gets none.
    @Test func theFieldsOwnRequestIsHonoured() {
        #expect(
            AutomaticShift.state(
                documentBefore: "John ",
                autocapitalization: .words,
                current: .off
            ) == .on
        )
        #expect(
            AutomaticShift.state(
                documentBefore: "",
                autocapitalization: .none,
                current: .on
            ) == .off
        )
        #expect(
            AutomaticShift.state(
                documentBefore: "anything",
                autocapitalization: .allCharacters,
                current: .off
            ) == .locked
        )
    }

    /// A caps lock the user engaged outranks every automatic decision, and an
    /// unanswered read must not quietly cancel it either.
    @Test func anEngagedCapsLockIsNeverOverridden() {
        #expect(
            AutomaticShift.state(
                documentBefore: "hello ",
                autocapitalization: .sentences,
                current: .locked
            ) == nil
        )
        #expect(
            AutomaticShift.state(
                documentBefore: nil,
                autocapitalization: .sentences,
                current: .locked
            ) == nil
        )
    }
}
