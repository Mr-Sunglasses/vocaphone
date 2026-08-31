import Testing
import UIKit

/// Geometry that has to hold at every width the app ships on, and at every
/// height the user can choose. Visual review cannot be asked to spot a spacebar
/// five points off centre on one of twelve combinations.
@MainActor
struct KeyboardGeometryTests {
    /// Small iPhone, iPhone SE class, 14/15 Pro class, and Max class.
    private static let widths: [CGFloat] = [320, 375, 393, 430]

    private static let portrait = UITraitCollection { $0.verticalSizeClass = .regular }
    private static let landscape = UITraitCollection { $0.verticalSizeClass = .compact }
    private static let regular = UITraitCollection {
        $0.verticalSizeClass = .regular
        $0.horizontalSizeClass = .regular
    }

    private static func makeGrid(
        width: CGFloat,
        traits: UITraitCollection = portrait,
        preference: KeyboardHeightPreference = .standard,
        plane: KeyPlane = .letters,
        includesGlobe: Bool = true
    ) -> KeyGridView {
        let metrics = KeyboardMetrics.resolved(for: traits, preference: preference)
        let grid = KeyGridView(metrics: metrics, palette: KeyboardPalette(isDark: false))
        grid.showsGlobeKey = includesGlobe
        grid.plane = plane
        grid.frame = CGRect(x: 0, y: 0, width: width, height: metrics.gridHeight)
        grid.layoutIfNeeded()
        return grid
    }

    private static func rows(in grid: KeyGridView) -> [[KeyView]] {
        Dictionary(grouping: grid.keyViews) { ($0.frame.minY * 10).rounded() }
            .sorted { $0.key < $1.key }
            .map { $0.value.sorted { $0.frame.minX < $1.frame.minX } }
    }

    // MARK: - Height preference

    @Test func theThreeHeightsAreOrderedAndDistinct() {
        let heights = KeyboardHeightPreference.allCases.map {
            KeyboardMetrics.resolved(for: Self.portrait, preference: $0)
        }
        #expect(heights[0].keyHeight < heights[1].keyHeight)
        #expect(heights[1].keyHeight < heights[2].keyHeight)
        // Compact must not go so small that the preview is dropped: a preview is
        // how the user sees what they typed under their own fingertip.
        let allShowPreviews = heights.allSatisfy(\.showsPreview)
        #expect(allShowPreviews)
    }

    /// The default uses the same vertical rhythm measured from Apple's iOS 26
    /// keyboard, including the full-height bottom row.
    @Test func standardUsesTheNativeVerticalRhythm() {
        let standard = KeyboardMetrics.resolved(for: Self.portrait, preference: .standard)
        #expect(standard.keyHeight == 43)
        #expect(standard.rowGap == 11)
        #expect(standard.gridHeight == 205)
    }

    /// Reference measurements come from the Apple keyboard on the same 402pt
    /// iPhone 17 simulator. The extension receives 390pt after its 6pt chrome
    /// inset on each side, so screen coordinates below add that inset back.
    @Test func defaultPortraitMatchesTheIPhone17SystemKeyboard() {
        let chromeInset: CGFloat = 6
        let grid = Self.makeGrid(width: 390, includesGlobe: false)
        let rows = Self.rows(in: grid)
        let q = rows[0][0]
        let a = rows[1][0]
        let shift = rows[2][0]
        let delete = rows[2].last!
        let plane = rows[3][0]
        let space = rows[3][1]
        let newline = rows[3][2]

        // Apple: Q x 6.67, width 33.33; A x 26.33; Shift/Delete width 45.33.
        #expect(abs(q.frame.minX + chromeInset - 6.67) < 0.75)
        #expect(abs(q.frame.width - 33.33) < 0.75)
        #expect(abs(a.frame.minX + chromeInset - 26.33) < 0.75)
        #expect(abs(shift.frame.width - 45.33) < 0.75)
        #expect(abs(delete.frame.width - 45.33) < 0.75)

        // Apple: four 43pt rows separated by 11pt gaps.
        #expect(rows.map { $0[0].frame.minY } == [0, 54, 108, 162])
        #expect(rows.map { $0[0].frame.height } == [43, 43, 43, 43])

        // With the globe in iOS's lower system row, Apple uses 2.5 / 5 / 2.5
        // columns here instead of shrinking both modifiers around a huge Space.
        #expect(abs(plane.frame.width - 92.67) < 0.75)
        #expect(abs(space.frame.width - 191.33) < 0.75)
        #expect(abs(newline.frame.width - 92.67) < 0.75)
    }

    /// Whatever the preference, the whole keyboard has to fit a phone. The
    /// tallest combination is the one worth pinning.
    @Test func theTallestKeyboardStillFitsAPhoneScreen() {
        let grid = KeyboardMetrics.resolved(for: Self.portrait, preference: .tall)
        let bar = DictationBarMetrics.resolved(for: Self.portrait, preference: .tall)
        // 667pt is the shortest screen the deployment target reaches.
        #expect(grid.gridHeight + bar.expandedHeight < 667 * 0.62)
    }

    /// Landscape and regular-width canvases keep their own metrics: one has no
    /// height to give away, the other was never sized from the phone preference.
    @Test func landscapeAndRegularWidthIgnoreThePreference() {
        for preference in KeyboardHeightPreference.allCases {
            #expect(
                KeyboardMetrics.resolved(for: Self.landscape, preference: preference)
                    == KeyboardMetrics.resolved(for: Self.landscape, preference: .standard)
            )
            #expect(
                KeyboardMetrics.resolved(for: Self.regular, preference: preference)
                    == KeyboardMetrics.resolved(for: Self.regular, preference: .standard)
            )
        }
        #expect(
            DictationBarMetrics.resolved(for: Self.landscape, preference: .tall)
                == DictationBarMetrics.resolved(for: Self.landscape, preference: .compact)
        )
    }

    /// The bar moves with the keys, but by less: its content is text and
    /// controls whose legibility does not follow thumb ergonomics.
    @Test func theBarScalesModestlyWithTheChosenHeight() {
        let compact = DictationBarMetrics.resolved(for: Self.portrait, preference: .compact)
        let standard = DictationBarMetrics.resolved(for: Self.portrait, preference: .standard)
        let tall = DictationBarMetrics.resolved(for: Self.portrait, preference: .tall)

        #expect(compact.collapsedHeight < standard.collapsedHeight)
        #expect(standard.collapsedHeight < tall.collapsedHeight)
        #expect(tall.collapsedHeight - compact.collapsedHeight < 12)
        // The continuous radius stays in the 20–24pt band the design standard
        // reserves for the recording surface, whatever the scale factor did.
        for metrics in [compact, standard, tall] {
            #expect(metrics.cornerRadius >= 20)
            #expect(metrics.cornerRadius <= 24)
        }
    }

    /// The whole point of putting the strip *inside* the bar rather than above
    /// it: the keyboard gains a suggestion row and gets **shorter**.
    ///
    /// A third region would have taken the keyboard to roughly 337 pt, against
    /// about 291 pt for a system keyboard that already has a strip — more of the
    /// host app covered, to add a feature meant to make it feel more native.
    @Test func addingTheStripMadeTheKeyboardShorter() {
        // The heights this keyboard shipped with, before the strip existed.
        let previousIdleBar: CGFloat = 72
        let chrome = 2 * 6 + 7.0

        for preference in KeyboardHeightPreference.allCases {
            let grid = KeyboardMetrics.resolved(for: Self.portrait, preference: preference)
            let bar = DictationBarMetrics.resolved(for: Self.portrait, preference: preference)
            let idleTotal = chrome + bar.stripHeight + grid.gridHeight
            let previousTotal = chrome + previousIdleBar + grid.gridHeight
            #expect(
                idleTotal < previousTotal,
                "\\(preference) idle keyboard is \\(idleTotal)pt, was \\(previousTotal)pt"
            )
        }

        // The pinned reference for the default: 6pt inset twice, a 54pt strip,
        // 7pt of spacing and the native-rhythm 205pt grid.
        let standardGrid = KeyboardMetrics.resolved(for: Self.portrait, preference: .standard)
        let standardBar = DictationBarMetrics.resolved(for: Self.portrait, preference: .standard)
        #expect(standardBar.stripHeight == 54)
        #expect(chrome + standardBar.stripHeight + standardGrid.gridHeight == 278)
    }

    /// The strip is the shortest of the three bar shapes, in every orientation
    /// and at every height — otherwise the idle keyboard would be paying for a
    /// row it is not showing.
    @Test func theStripIsAlwaysTheShortestBar() {
        for traits in [Self.portrait, Self.landscape, Self.regular] {
            for preference in KeyboardHeightPreference.allCases {
                let bar = DictationBarMetrics.resolved(for: traits, preference: preference)
                #expect(bar.height(for: .strip, expanded: false) <= bar.collapsedHeight)
                #expect(bar.height(for: .status, expanded: true) == bar.expandedHeight)
                // And a chip stays a target a thumb can actually hit.
                #expect(bar.chipHeight >= 38)
            }
        }
    }

    // MARK: - Bottom row

    /// The identity the bottom row is built on: the spacebar is centred exactly
    /// when the column totals either side of it are equal. Checked as columns
    /// rather than points because that is the claim the layout actually makes.
    @Test func theBottomRowColumnsBalanceAroundTheSpacebar() {
        for includesGlobe in [true, false] {
            for includesPunctuation in [true, false] {
                let columns = KeyLayout.BottomRowColumns.resolved(
                    includesGlobe: includesGlobe,
                    includesPunctuation: includesPunctuation
                )
                #expect(
                    abs(columns.centreOffset) < 0.001,
                    """
                    globe \(includesGlobe), punctuation \(includesPunctuation) leans \
                    \(columns.centreOffset) columns
                    """
                )
                #expect(columns.newline >= KeyLayout.minimumReturnColumns)
                #expect(columns.planeSwitch >= 1.25)
            }
        }
    }

    /// And the same claim, measured on laid-out frames, at every width and in
    /// every plane. The old row leaned about five points right on a 393pt phone.
    @Test func theSpacebarSitsOnTheKeyboardCentre() {
        for width in Self.widths {
            for plane in [KeyPlane.letters, .numbers, .symbols] {
                for includesGlobe in [true, false] {
                    let grid = Self.makeGrid(
                        width: width,
                        plane: plane,
                        includesGlobe: includesGlobe
                    )
                    let space = grid.keyViews.first { $0.spec.cap == .space }
                    #expect(space != nil)
                    guard let space else { continue }
                    #expect(
                        abs(space.frame.midX - width / 2) < 1,
                        """
                        \(plane) at \(width)pt: spacebar centre is \
                        \(space.frame.midX), keyboard centre is \(width / 2)
                        """
                    )
                }
            }
        }
    }

    /// The globe is required on a third-party keyboard, and removing it is not
    /// an available answer to a geometry problem.
    @Test func theGlobeKeyIsPresentWheneverITOSAsksForIt() {
        let grid = Self.makeGrid(width: 393, includesGlobe: true)
        let hasGlobe = grid.keyViews.contains { $0.spec.cap == .globe }
        #expect(hasGlobe)
    }

    // MARK: - Coverage

    /// Every gutter and every outer edge belongs to a key, at every width, in
    /// every plane, at every height, and in landscape — where keys are shorter
    /// than 44 points and the hit rectangles are the only thing keeping the row
    /// typable.
    @Test func hitRectanglesTileTheWholeTypingSurface() {
        for width in Self.widths {
            for preference in KeyboardHeightPreference.allCases {
                for traits in [Self.portrait, Self.landscape] {
                    for plane in [KeyPlane.letters, .numbers, .symbols] {
                        let grid = Self.makeGrid(
                            width: width,
                            traits: traits,
                            preference: preference,
                            plane: plane
                        )
                        for row in Self.rows(in: grid) {
                            for (left, right) in zip(row, row.dropFirst()) {
                                #expect(left.hitRect.maxX >= right.hitRect.minX - 0.01)
                            }
                            #expect(row.first!.hitRect.minX <= 0)
                            #expect(row.last!.hitRect.maxX >= width)
                        }
                        // Top and bottom edges too, not just the sides.
                        let rows = Self.rows(in: grid)
                        let coversTop = rows.first!.allSatisfy { $0.hitRect.minY <= 0 }
                        let coversBottom = rows.last!.allSatisfy {
                            $0.hitRect.maxY >= grid.bounds.height
                        }
                        #expect(coversTop)
                        #expect(coversBottom)
                    }
                }
            }
        }
    }

    /// Nothing may be drawn outside the grid except the preview, which is
    /// deliberately allowed to rise above the top row.
    @Test func noKeyEscapesItsGrid() {
        for width in Self.widths {
            for preference in KeyboardHeightPreference.allCases {
                let grid = Self.makeGrid(width: width, preference: preference)
                for key in grid.keyViews {
                    #expect(key.frame.minX >= -0.5)
                    #expect(key.frame.maxX <= width + 0.5)
                    #expect(key.frame.minY >= -0.5)
                    #expect(key.frame.maxY <= grid.bounds.height + 0.5)
                }
            }
        }
    }

    /// Single-column keys share one width in every row and every plane, which is
    /// what keeps the columns visually aligned.
    @Test func singleColumnKeysShareOneWidthInEveryPlane() {
        for width in Self.widths {
            for plane in [KeyPlane.letters, .numbers, .symbols] {
                let grid = Self.makeGrid(width: width, plane: plane)
                let widths = Set(
                    grid.keyViews
                        .filter { $0.spec.width == .unit }
                        .map { ($0.frame.width * 100).rounded() }
                )
                #expect(widths.count == 1, "\(plane) at \(width)pt split into \(widths)")
            }
        }
    }
}
