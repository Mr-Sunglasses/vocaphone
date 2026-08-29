import Testing

struct SnippetExpanderTests {
    private let expander = SnippetExpander()

    @Test func noSnippetsLeavesTextUnchanged() {
        #expect(expander.expand(in: "call me at brb", using: []) == "call me at brb")
    }

    @Test func emptyTriggersAreIgnored() {
        let snippets = [Snippet(trigger: "   ", expansion: "should never appear")]
        #expect(expander.expand(in: "brb", using: snippets) == "brb")
    }

    /// A blank expansion must leave the trigger alone, not delete it.
    @Test func blankExpansionsAreIgnored() {
        let snippets = [Snippet(trigger: "brb", expansion: "   ")]
        #expect(expander.expand(in: "brb in five", using: snippets) == "brb in five")
    }

    @Test func matchingIsCaseInsensitive() {
        let snippets = [Snippet(trigger: "brb", expansion: "be right back")]
        #expect(expander.expand(in: "BRB everyone", using: snippets) == "be right back everyone")
    }

    /// Word-character triggers use `\b`, so "sig" inside "signature" is left
    /// alone — only a whole-word match expands.
    @Test func wordBoundaryTriggerDoesNotMatchInsideALongerWord() {
        let snippets = [Snippet(trigger: "sig", expansion: "Kanishk Pachauri")]
        #expect(expander.expand(in: "please add your signature", using: snippets) == "please add your signature")
        #expect(expander.expand(in: "please add your sig", using: snippets) == "please add your Kanishk Pachauri")
    }

    /// A punctuation-only trigger has no word character on either side, so
    /// `\b` never fires there; the non-whitespace lookaround is what lets it
    /// still match at the very start and end of the string.
    @Test func punctuationOnlyTriggerMatchesAtStringEdges() {
        let snippets = [Snippet(trigger: "))", expansion: "closing")]
        #expect(expander.expand(in: "))", using: snippets) == "closing")
        #expect(expander.expand(in: "text ))", using: snippets) == "text closing")
    }

    /// The longer trigger has to win, or "good morning" would fire first and
    /// strand "team" behind an expansion that was never meant to include it.
    @Test func longerTriggerWinsOverAShorterSubstring() {
        let snippets = [
            Snippet(trigger: "good morning", expansion: "Good morning to you"),
            Snippet(trigger: "good morning team", expansion: "Good morning, team!")
        ]
        #expect(
            expander.expand(in: "good morning team", using: snippets)
                == "Good morning, team!"
        )
    }

    /// One combined regex rather than looping per snippet: an expansion that
    /// happens to contain another trigger must not itself get re-expanded.
    @Test func anExpansionContainingAnotherTriggerIsNotReExpanded() {
        let snippets = [
            Snippet(trigger: "sig", expansion: "sent from my brb device"),
            Snippet(trigger: "brb", expansion: "be right back")
        ]
        #expect(expander.expand(in: "sig", using: snippets) == "sent from my brb device")
    }

    /// Boundaries are spelled out as a Unicode class rather than left to
    /// `\b`, so a trigger outside ASCII matches here and on Android alike.
    @Test func nonASCIITriggerExpands() {
        let snippets = [Snippet(trigger: "büro", expansion: "the office")]
        #expect(
            expander.expand(in: "meet me at büro later", using: snippets)
                == "meet me at the office later"
        )
        #expect(
            expander.expand(in: "the bürogebäude is closed", using: snippets)
                == "the bürogebäude is closed"
        )
    }

    @Test func nonLatinScriptTriggerExpands() {
        let snippets = [Snippet(trigger: "पता", expansion: "221B Baker Street")]
        #expect(
            expander.expand(in: "भेजें पता पर", using: snippets)
                == "भेजें 221B Baker Street पर"
        )
    }

    @Test func caseFoldingAppliesToNonASCIITriggers() {
        let snippets = [Snippet(trigger: "über", expansion: "above")]
        #expect(expander.expand(in: "ÜBER all", using: snippets) == "above all")
    }

    /// A trigger stored with stray whitespace still matches on its own words,
    /// rather than being compiled with the padding baked into the pattern.
    @Test func triggerWhitespaceIsIgnoredWhenMatching() {
        let snippets = [Snippet(trigger: "  brb  ", expansion: "be right back")]
        #expect(expander.expand(in: "brb everyone", using: snippets) == "be right back everyone")
    }

    /// Replacement runs in reverse match order so earlier ranges in the
    /// string stay valid while later ones are rewritten.
    @Test func multipleMatchesInOneStringAllExpand() {
        let snippets = [
            Snippet(trigger: "addr", expansion: "221B Baker Street"),
            Snippet(trigger: "sig", expansion: "Kanishk")
        ]
        #expect(
            expander.expand(in: "addr — see you there, sig", using: snippets)
                == "221B Baker Street — see you there, Kanishk"
        )
    }
}
