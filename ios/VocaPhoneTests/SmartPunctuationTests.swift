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
