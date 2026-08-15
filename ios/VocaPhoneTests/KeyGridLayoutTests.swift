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

    /// Shift and delete absorb whatever the seven letters leave, which is what
    /// keeps the third row aligned with the ten-key row above it.
    @Test func modifierKeysAbsorbTheRemainderOfTheirRow() {
        let grid = Self.makeGrid()
        let row = Self.rowsByPosition(in: grid)[2]
        let shift = row.first!
        let delete = row.last!
        #expect(shift.spec.cap == .shift)
        #expect(delete.spec.cap == .delete)
        #expect(abs(shift.frame.width - delete.frame.width) < 0.5)
        #expect(shift.frame.width > row[1].frame.width)
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

        grid.leadingPunctuation = "@"
        var caps = grid.keyViews.map(\.spec.cap)
        #expect(caps.contains(.character("@")))
        #expect(caps.contains(.character(".")))

        grid.leadingPunctuation = "/"
        caps = grid.keyViews.map(\.spec.cap)
        #expect(caps.contains(.character("/")))
        #expect(!caps.contains(.character("@")))

        grid.leadingPunctuation = nil
        caps = grid.keyViews.map(\.spec.cap)
        #expect(!caps.contains(.character("/")))
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
