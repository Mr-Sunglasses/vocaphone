import Testing

/// The numbers and symbols planes are a detour from letters, as they are on
/// the system keyboard.
@MainActor
struct KeyPlaneReturnTests {
    @Test func aSpaceAfterTypingANumberReturnsToLetters() {
        #expect(
            KeyGridView.planeAfterCommit(text: " ", plane: .numbers, homePlane: .letters, typedOnPlane: true)
                == .letters
        )
        #expect(
            KeyGridView.planeAfterCommit(text: " ", plane: .symbols, homePlane: .letters, typedOnPlane: true)
                == .letters
        )
    }

    @Test func aSpaceStraightAfterSwitchingStays() {
        #expect(
            KeyGridView.planeAfterCommit(text: " ", plane: .numbers, homePlane: .letters, typedOnPlane: false)
                == nil
        )
    }

    @Test func anApostropheReturnsToLetters() {
        #expect(
            KeyGridView.planeAfterCommit(text: "'", plane: .numbers, homePlane: .letters, typedOnPlane: false)
                == .letters
        )
    }

    @Test func otherSymbolsStay() {
        #expect(
            KeyGridView.planeAfterCommit(text: "5", plane: .numbers, homePlane: .letters, typedOnPlane: true)
                == nil
        )
    }

    @Test func aFieldThatOpensOnNumbersKeepsThem() {
        #expect(
            KeyGridView.planeAfterCommit(text: " ", plane: .numbers, homePlane: .numbers, typedOnPlane: true)
                == nil
        )
        #expect(
            KeyGridView.planeAfterCommit(text: " ", plane: .letters, homePlane: .letters, typedOnPlane: true)
                == nil
        )
    }
}
