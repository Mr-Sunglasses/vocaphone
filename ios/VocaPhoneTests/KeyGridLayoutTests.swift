import Testing
import UIKit

@MainActor
struct KeyGridLayoutTests {
    private static let referenceWidth: CGFloat = 393

    private static func makeGrid(
        traits: UITraitCollection = UITraitCollection { $0.verticalSizeClass = .regular },
        plane: KeyPlane = .letters
    ) -> KeyGridView {
        let metrics = KeyboardMetrics.resolved(for: traits)
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.plane = plane
        grid.frame = CGRect(
            x: 0,
            y: 0,
            width: referenceWidth,
            height: metrics.gridHeight
        )
        grid.layoutIfNeeded()
        return grid
    }

    /// Rows used to be built from three separate hardcoded widths, so the
    /// columns visibly failed to line up. Every single-column key must now
    /// resolve to the same width.
    @Test func letterColumnsShareOneWidthAcrossEveryRow() {
        let grid = Self.makeGrid()
        let widths = Set(
            grid.keyViews
                .filter { $0.spec.width == .unit }
                .map { ($0.frame.width * 100).rounded() }
        )
        #expect(widths.count == 1)
    }

    @Test func fullWidthRowsSpanTheSameGrid() {
        let grid = Self.makeGrid()
        let inset = grid.metrics.sideInset
        let rows = Self.rowsByPosition(in: grid)
        // The home row centres itself; the other three fill the width.
        for row in [rows[0], rows[2], rows[3]] {
            #expect(abs(row.first!.frame.minX - inset) < 0.5)
            #expect(abs(row.last!.frame.maxX - (Self.referenceWidth - inset)) < 0.5)
        }
    }

    /// The home row's indent is half a column, derived rather than hardcoded, so
    /// it stays correct at any width.
    @Test func homeRowIndentsByHalfAColumn() {
        let grid = Self.makeGrid()
        let metrics = grid.metrics
        let available = Self.referenceWidth - 2 * metrics.sideInset
        let unit = (available - 9 * metrics.columnGap) / 10
        let homeRow = Self.rowsByPosition(in: grid)[1]

        let indent = homeRow.first!.frame.minX - metrics.sideInset
        #expect(abs(indent - (unit + metrics.columnGap) / 2) < 0.5)
        let trailing = Self.referenceWidth - metrics.sideInset - homeRow.last!.frame.maxX
        #expect(abs(indent - trailing) < 0.5)
    }

    /// Shift and Delete keep the native visual width while their invisible
    /// target slots still absorb the remainder and tile the entire row.
    @Test func letterModifiersUseNativeVisualWidthsAndFullHitTargets() {
        let grid = Self.makeGrid()
        let row = Self.rowsByPosition(in: grid)[2]
        let shift = row.first!
        let delete = row.last!
        #expect(shift.spec.cap == .shift)
        #expect(delete.spec.cap == .delete)
        #expect(abs(shift.frame.width - delete.frame.width) < 0.5)
        #expect(shift.frame.width > row[1].frame.width)
        #expect(shift.hitRect.maxX >= row[1].hitRect.minX)
        #expect(delete.hitRect.minX <= row[row.count - 2].hitRect.maxX)
    }

    @Test func hitTargetsCoverTheGuttersWithoutGaps() {
        let grid = Self.makeGrid()
        for row in Self.rowsByPosition(in: grid) {
            for (left, right) in zip(row, row.dropFirst()) {
                #expect(left.hitRect.maxX >= right.hitRect.minX - 0.01)
            }
            #expect(row.first!.hitRect.minX <= 0)
            #expect(row.last!.hitRect.maxX >= Self.referenceWidth)
        }
    }

    @Test func numbersAndSymbolPlanesReachCharactersLettersCannot() {
        let numbers = Self.makeGrid(plane: .numbers)
        let numberCaps = numbers.keyViews.map(\.spec.cap)
        #expect(numberCaps.contains(.character("1")))
        #expect(numberCaps.contains(.character("'")))
        #expect(numberCaps.contains(.character("?")))
        #expect(numberCaps.contains(.plane(.symbols)))
        #expect(numberCaps.contains(.plane(.letters)))

        let symbols = Self.makeGrid(plane: .symbols)
        let symbolCaps = symbols.keyViews.map(\.spec.cap)
        #expect(symbolCaps.contains(.character("#")))
        #expect(symbolCaps.contains(.character("€")))
        #expect(symbolCaps.contains(.plane(.numbers)))
    }

    @Test func lettersPlaneOffersASwitchToNumbers() {
        let grid = Self.makeGrid()
        #expect(grid.keyViews.map(\.spec.cap).contains(.plane(.numbers)))
    }

    /// A landscape phone has almost no height to give away; the old fixed
    /// geometry would have covered nearly the whole screen.
    @Test func compactHeightTraitsShrinkTheGrid() {
        let portrait = KeyboardMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .regular }
        )
        let landscape = KeyboardMetrics.resolved(
            for: UITraitCollection { $0.verticalSizeClass = .compact }
        )
        let pad = KeyboardMetrics.resolved(
            for: UITraitCollection {
                $0.verticalSizeClass = .regular
                $0.horizontalSizeClass = .regular
            }
        )

        #expect(landscape.gridHeight < portrait.gridHeight * 0.75)
        #expect(pad.gridHeight > portrait.gridHeight)
    }

    /// A plain QWERTY bottom row is `123`, the globe, space and return — the
    /// same four keys the system keyboard has there, and nothing else. The
    /// comma and full stop this keyboard used to add were two keys' worth of
    /// spacebar, and they are not what anyone reaching for that row expects.
    @Test func thePlainLettersPlaneHasNoPunctuationOnTheBottomRow() {
        let grid = Self.makeGrid()
        let caps = grid.keyViews.map(\.spec.cap)
        #expect(!caps.contains(.character(",")))
        #expect(!caps.contains(.character(".")))

        let bottomRow = Self.rowsByPosition(in: grid)[3].map(\.spec.cap)
        #expect(bottomRow == [.plane(.numbers), .globe, .space, .newline])
    }

    /// Email and URL fields get their separator back, because that is also what
    /// the system keyboard does: `@` and `.` for email, `/` and `.` for a URL.
    @Test func emailAndUrlFieldsGetTheirSeparatorBack() {
        let grid = Self.makeGrid()

        grid.punctuation = KeyLayout.BottomRowPunctuation(leading: "@", trailing: ".")
        var caps = grid.keyViews.map(\.spec.cap)
        #expect(caps.contains(.character("@")))
        #expect(caps.contains(.character(".")))

        grid.punctuation = KeyLayout.BottomRowPunctuation(leading: "/", trailing: ".")
        caps = grid.keyViews.map(\.spec.cap)
        #expect(caps.contains(.character("/")))
        #expect(!caps.contains(.character("@")))

        grid.punctuation = nil
        caps = grid.keyViews.map(\.spec.cap)
        #expect(!caps.contains(.character("/")))
        #expect(!caps.contains(.character(".")))
    }

    /// A Twitter-style field gets `@` and `#`, which are the two characters it
    /// exists for. The trailing slot used to be hardcoded to a full stop, so the
    /// pair could not be expressed at all.
    @Test func twitterFieldsGetTheHandleAndHashKeys() {
        let grid = Self.makeGrid()
        grid.punctuation = KeyLayout.BottomRowPunctuation(leading: "@", trailing: "#")
        let caps = grid.keyViews.map(\.spec.cap)
        #expect(caps.contains(.character("@")))
        #expect(caps.contains(.character("#")))
        #expect(!caps.contains(.character(".")))
    }

    @Test func shiftResolvesCharacterCaseAndSpokenLabel() {
        #expect(KeyCap.character("q").resolvedText(shift: .off) == "q")
        #expect(KeyCap.character("q").resolvedText(shift: .on) == "Q")
        #expect(KeyCap.character("q").resolvedText(shift: .locked) == "Q")
        #expect(KeyCap.character(".").accessibilityLabel(shift: .off) == "Period")
        #expect(KeyCap.shift.accessibilityLabel(shift: .on) == "Shift")
    }

    /// Groups laid-out keys into visual rows, top to bottom and left to right.
    private static func rowsByPosition(in grid: KeyGridView) -> [[KeyView]] {
        Dictionary(grouping: grid.keyViews) { ($0.frame.minY * 10).rounded() }
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.frame.minX < $1.frame.minX } }
    }
}

/// The numeric keypads, which a `.numberPad` or `.phonePad` field used to be
/// denied entirely: it got the symbols plane, so a phone number was typed
/// against `-/:;()$&@"`.
@MainActor
struct KeypadLayoutTests {
    @Test func aNumberPadIsAKeypadRatherThanTheSymbolsPlane() {
        let rows = KeyLayout.keypadRows(for: .numberPad, includesGlobe: false)
        #expect(rows.count == 4, "the keypad must occupy the grid's own four rows")
        #expect(rows[0].keys.map(\.cap) == [
            .character("1"), .character("2"), .character("3"),
        ])
        #expect(rows[2].keys.map(\.cap) == [
            .character("7"), .character("8"), .character("9"),
        ])
        // The empty corner is genuinely empty. Stretching the zero across it
        // would put a target where the user is reaching for nothing.
        #expect(rows[3].keys.map(\.cap) == [.blank, .character("0"), .delete])
        // Nothing on a keypad may leave it: there is no plane key to leave by.
        #expect(!rows.flatMap(\.keys).contains { if case .plane = $0.cap { true } else { false } })
    }

    @Test func theGlobeTakesTheEmptyCornerWhenItIsNeeded() {
        let rows = KeyLayout.keypadRows(for: .numberPad, includesGlobe: true)
        #expect(rows[3].keys.map(\.cap) == [.globe, .character("0"), .delete])
    }

    /// The globe must never cost a keypad the only key that types its own
    /// character: these layouts have no second plane and no duplicate, so a
    /// displaced "." is a decimal pad that cannot type a decimal point.
    @Test func theGlobeNeverDisplacesAKeypadsOnlySeparator() {
        for (plane, required) in [(KeyPlane.decimalPad, "."), (.phonePad, "+")] {
            for globe in [true, false] {
                let caps = KeyLayout.keypadRows(for: plane, includesGlobe: globe)
                    .flatMap(\.keys)
                    .map(\.cap)
                #expect(
                    caps.contains(.character(required)),
                    "\(plane) with globe=\(globe) lost its \(required)"
                )
                #expect(caps.contains(.delete))
                #expect(caps.contains(.character("0")))
                #expect(caps.contains(.globe) == globe)
            }
        }
    }

    @Test func aDecimalPadSpendsTheCornerOnItsSeparator() {
        let rows = KeyLayout.keypadRows(for: .decimalPad, includesGlobe: false)
        #expect(rows[3].keys.first?.cap == .character("."))
    }

    /// A phone pad has to be able to type the characters a dialable number
    /// contains, so it spends the delete slot on "+" and moves delete up.
    @Test func aPhonePadSpendsTheCornerOnThePlus() {
        let rows = KeyLayout.keypadRows(for: .phonePad, includesGlobe: false)
        #expect(rows[3].keys.map(\.cap) == [.character("+"), .character("0"), .delete])
    }

    /// Three columns in every row, and four only where a globe and a required
    /// separator both have to fit. The digits are always a regular block.
    @Test func theDigitsAreAlwaysARegularBlock() {
        for plane in [KeyPlane.numberPad, .phonePad, .decimalPad] {
            for globe in [true, false] {
                let rows = KeyLayout.keypadRows(for: plane, includesGlobe: globe)
                #expect(rows.count == 4)
                #expect(
                    rows.prefix(3).allSatisfy { $0.keys.count == 3 },
                    "\(plane) with globe=\(globe) has ragged digits"
                )
                #expect(rows.allSatisfy { $0.alignment == .centered })
                let needsFour = globe && plane != .numberPad
                #expect(rows[3].keys.count == (needsFour ? 4 : 3))
            }
        }
    }

    /// A blank is a hole, not a key. It must never take a touch, show a preview
    /// or fire on touch-down.
    @Test func aBlankIsNotInteractive() {
        #expect(!KeyCap.blank.isInteractive)
        #expect(!KeyCap.blank.isCharacter)
        #expect(KeyCap.character("0").isInteractive)
    }
}
