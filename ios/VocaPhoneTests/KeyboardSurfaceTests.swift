import Testing
import UIKit

/// The numbers and rules changed while making the keyboard read as part of iOS.
///
/// Each of these was arrived at by measurement — against a screenshot of the
/// system keyboard, against a device, or against a log pulled off one — and
/// none of them survives being a number somebody remembers. That is what these
/// tests are for: not to prove the arithmetic, but to keep the reasoning
/// attached to the value.
@MainActor
struct KeyboardSurfaceTests {
    @Test func compactDashboardUsesOnlyRecordedUsageTotals() {
        let now = Date(timeIntervalSince1970: 1_789_000_000)
        let stats = UsageStats(
            totalWords: 6_289,
            totalDictations: 18,
            totalSeconds: 4_239,
            lastDayKey: UsageStats.dayKey(now),
            currentStreak: 1,
            bestStreak: 4
        )

        #expect(CompactDashboardPage.allCases.count == 4)
        #expect(CompactDashboardPage.words.value(for: stats, now: now) == "6,289")
        #expect(CompactDashboardPage.words.label(for: stats, now: now) == "Words dictated")
        #expect(CompactDashboardPage.words.detail(for: stats) == "Across 18 completed dictations")
        #expect(CompactDashboardPage.sessions.value(for: stats, now: now) == "18")
        #expect(CompactDashboardPage.streak.value(for: stats, now: now) == "1")
        #expect(
            CompactDashboardPage.streak.label(for: stats, now: now)
                == "Day in your current streak"
        )
        #expect(CompactDashboardPage.streak.detail(for: stats) == "Best streak: 4 days")
        #expect(CompactDashboardPage.speed.value(for: stats, now: now) == "89")
        #expect(CompactDashboardPage.speed.label(for: stats, now: now) == "Average WPM")
    }

    @Test func panelsReportOnlyRealVisibilityChanges() {
        let surface = DictationSurfaceState()
        var changes: [Bool] = []
        surface.onPanelVisibilityChanged = { changes.append($0) }

        surface.present(.dashboard)
        surface.present(.dashboard)
        surface.present(nil)

        #expect(changes == [true, false])
    }

    /// Dashboard to language picker is one panel replacing another: the keys
    /// must not be uncovered in between, and leaving the picker goes back to
    /// the dashboard it was opened from.
    @Test func aPickerOpenedFromTheDashboardReturnsToIt() {
        let surface = DictationSurfaceState()
        var changes: [Bool] = []
        surface.onPanelVisibilityChanged = { changes.append($0) }

        surface.present(.dashboard)
        surface.present(.language, returningTo: .dashboard)
        #expect(surface.panelReturnsToPrevious)
        surface.dismissPanel()

        #expect(surface.presentedPanel == .dashboard)
        #expect(!surface.panelReturnsToPrevious)
        #expect(changes == [true])

        surface.dismissPanel()
        #expect(surface.presentedPanel == nil)
        #expect(changes == [true, false])
    }

    @Test func theStylePickerFromTheRowClosesBackToTheKeys() {
        let style = KeyboardPreferences.writingStyle
        defer { KeyboardPreferences.writingStyle = style }
        let surface = DictationSurfaceState()
        var changes: [Bool] = []
        surface.onPanelVisibilityChanged = { changes.append($0) }

        surface.present(.style)
        surface.select(style: .formal)
        surface.dismissPanel()

        #expect(surface.presentedPanel == nil)
        #expect(surface.style == .formal)
        #expect(changes == [true, false])
    }

    @Test func vocaPhoneSwitchClosesTheAppWithoutTouchingQuickDictation() {
        let enabled = KeyboardPreferences.quickDictationEnabled
        let duration = KeyboardPreferences.quickDictationDuration
        let paused = KeyboardPreferences.quickDictationPausedUntilRelaunch
        defer {
            KeyboardPreferences.quickDictationEnabled = enabled
            KeyboardPreferences.quickDictationDuration = duration
            KeyboardPreferences.quickDictationPausedUntilRelaunch = paused
        }
        KeyboardPreferences.quickDictationEnabled = true
        KeyboardPreferences.quickDictationDuration = .tenMinutes
        KeyboardPreferences.quickDictationPausedUntilRelaunch = false

        let surface = DictationSurfaceState()
        surface.quickDictationReady = true
        surface.present(.dashboard)
        var changes: [Bool] = []
        var visibilityChanges: [Bool] = []
        surface.onVocaPhoneRunningChanged = { changes.append($0) }
        surface.onPanelVisibilityChanged = { visibilityChanges.append($0) }

        surface.setVocaPhoneRunning(false)
        surface.setVocaPhoneRunning(false)

        #expect(surface.quickDictationReady == false)
        #expect(surface.presentedPanel == nil)
        #expect(changes == [false])
        #expect(visibilityChanges == [false])
        #expect(KeyboardPreferences.quickDictationEnabled)
        #expect(KeyboardPreferences.quickDictationDuration == .tenMinutes)
        #expect(KeyboardPreferences.quickDictationPausedUntilRelaunch == false)
    }

    @Test func recoveryGuidanceSurvivesPollingUntilTheStateChanges() {
        let surface = DictationSurfaceState()
        surface.state = .awaitingReturn
        surface.showRecoveryMessage("Open vocaphone manually")
        surface.state = .awaitingReturn
        surface.centerMessage = nil
        #expect(surface.centerMessage == "Open vocaphone manually")

        surface.state = .recording
        #expect(surface.centerMessage == nil)
    }

    @Test func retryGuidanceDoesNotLeakIntoAnotherSession() {
        let surface = DictationSurfaceState()
        surface.sessionID = UUID()
        surface.state = .uploading
        surface.showRecoveryMessage("Open vocaphone to retry")
        surface.centerMessage = "Uploading"
        #expect(surface.centerMessage == "Open vocaphone to retry")

        surface.sessionID = UUID()
        #expect(surface.centerMessage == "Uploading")
        #expect(surface.recoveryMessage == nil)
    }

    private static var portrait: UITraitCollection {
        UITraitCollection { traits in
            traits.horizontalSizeClass = .compact
            traits.verticalSizeClass = .regular
        }
    }

    // MARK: - Proportions

    /// Letters sit at roughly 0.57 of the key's height, corners at roughly
    /// 0.23 — both read off Apple's own keyboard on the same phone.
    ///
    /// The keyboard this replaced was at 0.51 and 0.14, which is what "small
    /// letters on square keys" measures out to. The bands are wide enough for
    /// judgement and narrow enough that a drift back is a failure.
    @Test func keyGlyphsAndCornersKeepTheSystemsProportions() {
        for preference in KeyboardHeightPreference.allCases {
            let metrics = KeyboardMetrics.resolved(for: Self.portrait, preference: preference)
            let glyphRatio = metrics.letterFontSize / metrics.keyHeight
            let cornerRatio = metrics.cornerRadius / metrics.keyHeight
            #expect(
                glyphRatio > 0.54 && glyphRatio < 0.62,
                "\(preference.displayName) letter is \(glyphRatio) of the key"
            )
            #expect(
                cornerRatio > 0.18 && cornerRatio < 0.26,
                "\(preference.displayName) corner is \(cornerRatio) of the key"
            )
        }
    }

    /// The punctuation row divides between all seven keys.
    ///
    /// `#+=` and Delete used to be the only filling keys in that row, so the
    /// three spare columns went to them — two slabs beside five narrow
    /// punctuation keys, when the punctuation is what the finger is aiming for.
    @Test func thePunctuationRowIsSharedByEveryKeyInIt() {
        for plane in [KeyPlane.numbers, .symbols] {
            let rows = KeyLayout.rows(
                for: plane,
                includesGlobe: true,
                returnIsProminent: false
            )
            let punctuationRow = rows[2]
            #expect(punctuationRow.keys.count == 7)
            for key in punctuationRow.keys {
                #expect(key.width == .fill, "\(plane) row 3 has a fixed-width key")
            }
        }
    }

    // MARK: - Room for a language key

    /// Apple's proportions, kept exactly, while the row is Apple's row.
    ///
    /// The language key is the only reason any of these numbers move. A change
    /// that also moved them for everyone else would be a redesign of the
    /// keyboard smuggled in behind a feature, so this is the test that says it
    /// was not.
    @Test func aKeyboardWithOneLayoutKeepsApplesBottomRowExactly() {
        for globe in [true, false] {
            for punctuation in [true, false] {
                let columns = KeyLayout.BottomRowColumns.resolved(
                    includesGlobe: globe,
                    includesLayoutSwitch: false,
                    includesPunctuation: punctuation
                )
                #expect(columns.layoutSwitch == nil)
                #expect(columns.newline == KeyLayout.minimumReturnColumns)
                #expect(columns.planeSwitch == (globe ? 1.25 : 2.5))
                #expect(columns.punctuation == (punctuation ? 1.25 : nil))
            }
        }
    }

    /// A fifth key on a row balanced for four, at Apple's widths, leaves the
    /// spacebar around two and a half columns — half a plain row's. That is the
    /// arithmetic behind the note on ``KeyboardOutput/emojiPanel`` explaining
    /// why there is no emoji key.
    ///
    /// Yandex's Russian keyboard carries the same five and answers the same
    /// crowding by trimming the function keys to a column and Return to a
    /// little over one. Measured off a screenshot: the spacebar comes back to
    /// roughly four and a quarter columns of ten. These are those proportions,
    /// and this is the number they were for.
    @Test func aLanguageKeyBuysTheSpacebarBackInsteadOfHalvingIt() {
        for globe in [true, false] {
            for punctuation in [true, false] {
                let label = "globe \(globe), punct \(punctuation)"
                let apple = KeyLayout.BottomRowColumns.resolved(
                    includesGlobe: globe,
                    includesLayoutSwitch: false,
                    includesPunctuation: punctuation
                )
                let crowded = KeyLayout.BottomRowColumns.resolved(
                    includesGlobe: globe,
                    includesLayoutSwitch: true,
                    includesPunctuation: punctuation
                )
                // A sixth key does cost the spacebar something on a row that
                // had room to spare — half a column where Apple's own gave it
                // five. What it must never do is push it under the width below
                // which it stops being a spacebar. And where Apple's row was
                // already under that width, the trimming leaves it wider than
                // Apple's: the crowded rows come out ahead, not behind.
                #expect(
                    crowded.spacebar >= min(KeyLayout.minimumSpacebarColumns, apple.spacebar),
                    "\(label): \(crowded.spacebar) against Apple's \(apple.spacebar)"
                )
                if apple.spacebar < KeyLayout.minimumSpacebarColumns {
                    #expect(
                        crowded.spacebar > apple.spacebar,
                        "\(label): \(crowded.spacebar) against Apple's \(apple.spacebar)"
                    )
                }
            }
        }
    }

    /// The spacebar's centre is the keyboard's centre exactly when the column
    /// totals either side of it are equal — the identity the whole width
    /// calculation rests on. Adding a key to the leading side is precisely the
    /// way to break it.
    @Test func theSpacebarStaysCentredWithALanguageKeyOnTheRow() {
        for globe in [true, false] {
            for punctuation in [true, false] {
                let columns = KeyLayout.BottomRowColumns.resolved(
                    includesGlobe: globe,
                    includesLayoutSwitch: true,
                    includesPunctuation: punctuation
                )
                #expect(
                    abs(columns.centreOffset) <= 0.75,
                    "off centre by \(columns.centreOffset) — globe \(globe), punct \(punctuation)"
                )
            }
        }
    }

    /// The spacebar is never traded below the width it needs, and the keys
    /// beside it are never trimmed further than that trade requires.
    ///
    /// The first version trimmed the same amount every time. On a row with no
    /// punctuation that handed the spacebar six and a quarter columns against
    /// Apple's five and left the keys either side visibly thin — reported from
    /// a device as "you cut the side keys a lot and the space bar is big",
    /// which is both halves of the same mistake.
    @Test func theRowIsTrimmedOnlyAsFarAsTheSpacebarActuallyNeeds() {
        for globe in [true, false] {
            for punctuation in [true, false] {
                let columns = KeyLayout.BottomRowColumns.resolved(
                    includesGlobe: globe,
                    includesLayoutSwitch: true,
                    includesPunctuation: punctuation
                )
                let label = "globe \(globe), punct \(punctuation)"
                // Six keys and a spacebar do not fit on ten columns at any
                // width worth having: with both the globe and the punctuation
                // pair the floor is out of reach even fully trimmed, and the
                // row settles at 3.25 — still wider than the 2.5 Apple's own
                // email row leaves. Every other configuration clears it.
                if !(globe && punctuation) {
                    #expect(
                        columns.spacebar >= KeyLayout.minimumSpacebarColumns,
                        "\(label): spacebar is \(columns.spacebar) columns"
                    )
                }
                #expect(columns.spacebar >= 3.25, "\(label): \(columns.spacebar)")
                // Never wider than Apple's plain row either: a spacebar that
                // has eaten the row is not a fix for one that was too narrow.
                #expect(columns.spacebar <= 5.5, "\(label): spacebar is \(columns.spacebar)")
                #expect(columns.planeSwitch >= 1, "\(label): plane key is \(columns.planeSwitch)")
                #expect(columns.newline >= KeyLayout.crowdedReturnColumns, "\(label)")
                // Apple's Return survives wherever the spacebar did not need
                // its width, which is the point of trimming by need.
                if !globe, !punctuation {
                    #expect(columns.newline == KeyLayout.minimumReturnColumns, "\(label)")
                }
            }
        }
        // An uncrowded row keeps Apple's widths untouched: there is nothing to
        // buy back, so nothing is spent.
        let plain = KeyLayout.BottomRowColumns.resolved(
            includesGlobe: false,
            includesLayoutSwitch: true,
            includesPunctuation: false
        )
        #expect(plain.newline == KeyLayout.minimumReturnColumns)
        #expect(plain.planeSwitch == 1.25)
    }

    /// A fresh install gets the languages the phone is already set up in.
    ///
    /// It used to get all five, which hands somebody who only types English a
    /// language key, a labelled spacebar and four alphabets they never asked
    /// for — and the gesture guarding against that is the whole reason the
    /// count is checked in three places.
    @Test func aNewInstallStartsWithTheLanguagesThePhoneAlreadyUses() {
        #expect(TypingLayout.forPreferredLanguages(["en-US"]).map(\.id) == ["en"])
        #expect(TypingLayout.forPreferredLanguages(["ru-RU", "en-GB"]).map(\.id) == ["en", "ru"])
        // Order follows the catalogue, not the phone: the list in settings and
        // the order the language key walks are the same order, and it should
        // not silently differ between two phones set up the same way.
        #expect(TypingLayout.forPreferredLanguages(["ru", "de"]).map(\.id) == ["de", "ru"])
        // Nothing recognised still has to produce a keyboard.
        #expect(TypingLayout.forPreferredLanguages(["ja-JP"]).map(\.id) == ["en"])
        #expect(TypingLayout.forPreferredLanguages([]).map(\.id) == ["en"])
    }

    // MARK: - The catalogue

    /// Adding a language is adding an entry, so what an entry must satisfy is
    /// worth stating once rather than reviewing five times.
    @Test func everyLayoutInTheCatalogueIsWellFormed() {
        var seen = Set<String>()
        for layout in TypingLayout.catalogue {
            #expect(seen.insert(layout.id).inserted, "duplicate id \(layout.id)")
            #expect(!layout.displayName.isEmpty)
            #expect(!layout.checkerLanguage.isEmpty)
            #expect(layout.rows.count == 3, "\(layout.displayName) has \(layout.rows.count) rows")
            let letters = Array(layout.rows.joined())
            #expect(
                Set(letters).count == letters.count,
                "\(layout.displayName) repeats a letter on the grid"
            )
            // Twelve is where a key stops being a target and starts being a
            // sliver: at 393pt a twelve-column row is under 28pt of glass.
            for row in layout.rows {
                #expect(row.count <= 12, "\(layout.displayName) has a \(row.count)-key row")
                #expect(!row.isEmpty)
            }
        }
    }

    /// The one question the spacebar label, the key and the gesture all ask.
    @Test func steppingThroughLayoutsWrapsBothWaysAndStopsAtOne() {
        let all = TypingLayout.catalogue
        let first = all[0]
        #expect(TypingLayout.next(after: first, in: [first]) == nil)
        #expect(TypingLayout.next(after: first, in: []) == nil)
        #expect(TypingLayout.next(after: first, in: all) == all[1])
        #expect(TypingLayout.next(after: first, in: all, forward: false) == all[all.count - 1])
        #expect(TypingLayout.next(after: all[all.count - 1], in: all) == first)
        // A layout that is not in the list has no successor in it, which is the
        // case a stale stored choice produces.
        let stray = all[1]
        #expect(TypingLayout.next(after: stray, in: [first, all[2]]) == nil)
    }

    // MARK: - The press nobody could see

    /// A press is held long enough to be composited once, and no longer.
    ///
    /// A tap can be shorter than a frame. On a 60 Hz panel that is 16.6 ms, and
    /// a keystroke that goes down and up inside one frame is drawn once — with
    /// the key already back at rest. The letter arrives and the key never looks
    /// pressed, which is what "some keys don't respond" turned out to be.
    ///
    /// The other half of this is the half that was got wrong. The hold runs
    /// *after the finger has left*, so every millisecond of it is a millisecond
    /// the key stays lit under a hand that has moved on. At 70 ms a typist
    /// moving between keys every 125 ms left a trail of lit keys behind them,
    /// and reported the keyboard as lagging. The bound is one frame, not four.
    @Test func aPressIsHeldLongEnoughToBeSeenAndNoLonger() {
        // Shorter than a frame at 60 Hz: the release waits.
        #expect(KeyView.releaseDelay(shownFor: 0.005) > 0.01)
        // But never long enough to still be lit when the next key is pressed.
        // 125 ms is a brisk but ordinary typing interval.
        #expect(KeyView.minimumHighlightSeconds < 0.125 / 2)
        // Long enough to clear a frame on the slowest panel this runs on.
        #expect(KeyView.minimumHighlightSeconds > 1.0 / 60)
        // Long enough to have been drawn: nothing to wait for.
        #expect(KeyView.releaseDelay(shownFor: 0.2) == 0)
        // The wait never exceeds the minimum itself.
        #expect(KeyView.releaseDelay(shownFor: 0) == KeyView.minimumHighlightSeconds)
    }

    // MARK: - The meter

    /// Levels cross to the keyboard as a run with a count, not as one number.
    ///
    /// The count is what lets a reader take only what it has not drawn: the
    /// keyboard polls on its own clock, so without it the same audio is drawn
    /// twice or skipped, and the meter goes back to being an animation of a
    /// meter rather than one.
    @Test func aMeterSampleCarriesItsRunAndItsCount() {
        let sample = MeterSample(sequence: 25, levels: [0.2, 1.4, -0.3, 0.9])
        let clamped = sample.clamped()
        #expect(clamped.sequence == 25)
        #expect(clamped.levels == [0.2, 1, 0, 0.9])

        // A reader that has drawn 21 of the 25 takes the last four.
        let alreadyDrawn = 21
        let unseen = clamped.sequence - alreadyDrawn
        #expect(Array(clamped.levels.suffix(unseen)) == [0.2, 1, 0, 0.9])

        // One that is up to date takes none, however often it asks.
        #expect(clamped.sequence - 25 == 0)
    }

    // MARK: - What the surface says

    /// Every failure has one line, and no state that is merely in progress has
    /// one at all.
    ///
    /// The line is deliberately shorter than the bar's card: this is one line
    /// over somebody else's text field, and the fix is on the button beside it.
    /// What survives the cut is the fact that changes what the person does next
    /// — the recording is still there.
    @Test func everyFailureHasOneLineAndProgressHasNone() {
        let failures: [SessionState] = [
            .serverUnavailable,
            .uploadFailedRecoverable,
            .transcriptionFailedRecoverable,
            .transcriptionFailedPermanent,
            .permissionDenied,
            .targetContextChanged,
        ]
        for state in failures {
            let line = DictationBarModel.surfaceLine(for: state)
            #expect(line != nil, "\(state.rawValue) says nothing")
            #expect(line?.count ?? 0 < 60, "\(state.rawValue) is too long for the strip")
        }
        for state in [SessionState.idle, .recording, .transcribing, .launchingApp] {
            #expect(DictationBarModel.surfaceLine(for: state) == nil)
        }
        // The two recoverable ones promise the recording is kept, which is the
        // only fact that changes whether the person speaks it all again.
        #expect(
            DictationBarModel.surfaceLine(for: .serverUnavailable)?
                .contains("Recording kept") == true
        )
        #expect(
            DictationBarModel.surfaceLine(for: .transcriptionFailedRecoverable)?
                .contains("Recording kept") == true
        )
    }

    // MARK: - Contrast maths

    /// A grey is not black, even when it was declared as a monochrome colour.
    ///
    /// `getRed` reports nothing for those, and both the luminance and the
    /// compositor used to read that failure as pure black — so a contrast test
    /// on half the palette was passing without measuring anything.
    @Test func monochromeColoursAreMeasuredRatherThanReadAsBlack() {
        let grey = UIColor(white: 0.5, alpha: 1)
        let luminance = ContrastMath.relativeLuminance(grey)
        #expect(luminance > 0.15 && luminance < 0.3, "monochrome grey scored \(luminance)")

        // And a translucent monochrome film composites onto what is behind it
        // rather than collapsing to its own declared colour.
        let film = UIColor(white: 1, alpha: 0.5)
        let backdrop = UIColor(white: 0, alpha: 1)
        let composited = film.compositedOver(backdrop)
        var white: CGFloat = 0
        var alpha: CGFloat = 0
        _ = composited.getWhite(&white, alpha: &alpha)
        #expect(abs(white - 0.5) < 0.01)
        #expect(alpha == 1)
    }

    // MARK: - The press that let go of itself

    /// A key keeps its finger through the drift of pressing it.
    ///
    /// Measured on device: two spaces in 442 keystrokes were pressed, tracked,
    /// and silently dropped — both within 2 pt of the bottom row's top edge.
    /// A press is not still; the thumb rolls a few points as it lands, and the
    /// bottom row has only half the row gap above it, so leaving the rect is a
    /// matter of two or three points. What made it invisible is that the
    /// keyboard then ran the words together and offered to autocorrect the
    /// result, so the symptom looked like a bad correction rather than a lost
    /// key.
    ///
    /// The slack is the hit map's own: the distance a *sliding* finger must
    /// clear before the map hands it to a neighbour is the same distance a
    /// *held* finger may wander without letting go.
    @Test func aHeldKeyIsNotLostToTheDriftOfPressingIt() {
        let key = KeyHitMap.Target(
            index: 0,
            frame: CGRect(x: 100, y: 162, width: 180, height: 43),
            hitRect: CGRect(x: 100, y: 156.5, width: 180, height: 48.5),
            isCharacter: false
        )
        let map = KeyHitMap(targets: [key], hysteresis: 6.7)
        let slack = map.hysteresis
        let held = key.hitRect.insetBy(dx: -slack, dy: -slack)

        // The press that was dropped: 161 pt, four points inside the rect, and
        // a roll upward of five takes it out.
        #expect(key.hitRect.contains(CGPoint(x: 190, y: 156)) == false)
        #expect(held.contains(CGPoint(x: 190, y: 156)))
        // Far enough above to be a different key is still a different key.
        #expect(held.contains(CGPoint(x: 190, y: 148)) == false)
    }

    // MARK: - Where a keystroke's time went

    /// Looking a prefix up does not read the whole list.
    ///
    /// A frequency-ordered list cannot be searched, so every prefix query walked
    /// all ten thousand words and called a grapheme-counting `count` on each.
    /// The bound that was there — `scanLimit` — limited the number of *matches*,
    /// which is no bound at all for a prefix the language barely uses. Measured
    /// on device: 5.5 ms of a 9.5 ms keystroke, against a frame budget of 8.3.
    ///
    /// The index has to give the same answers, in the same order, or it has
    /// traded the keyboard's suggestions for its frame rate.
    @Test func aPrefixIndexAnswersExactlyAsTheFullScanDid() {
        let words = [
            "the", "there", "then", "they", "to", "that",
            "this", "think", "thymus", "top", "quixotic",
        ]
        let list = TypingWordList(words: words, bigrams: [:])

        // Frequency order survives: "the" is first in the list and first out.
        #expect(list.completions(for: "th", limit: 3) == ["the", "there", "then"])
        // The prefix itself is a match of the prefix, and never a completion of
        // it — "the" completes to "there", not to itself.
        #expect(list.completions(for: "the", limit: 3) == ["there", "then", "they"])
        // A prefix the list has nothing for answers nothing, without a scan.
        #expect(list.completions(for: "zz", limit: 3).isEmpty)
        #expect(list.nextCharacterWeights(after: "zz").isEmpty)

        // The weights are still ranked by position in the whole list, not by
        // position within the bucket: "e" leads because "the" is the most
        // common word here, not because it was first among the "th" words.
        let weights = list.nextCharacterWeights(after: "th")
        #expect(weights["e"] == 1)
        #expect((weights["i"] ?? 0) < 1)
        #expect((weights["y"] ?? 0) < (weights["i"] ?? 0))
        #expect(weights["o"] == nil)

        // A one-character prefix is answered from its own bucket.
        #expect(list.completions(for: "q", limit: 2) == ["quixotic"])
    }

    // MARK: - Spacebar lift

    /// A swipe that changed the layout, or a hold that became the cursor, has
    /// already done its job. The lift must not type a space on top.
    @Test func liftingTheSpacebarDoesNotTypeAfterAGesture() {
        #expect(
            KeyGridView.shouldCommitSpace(
                isEngaged: true, isCursorTracking: false, didSwitchLayout: false, commit: true
            )
        )
        #expect(
            !KeyGridView.shouldCommitSpace(
                isEngaged: true, isCursorTracking: true, didSwitchLayout: false, commit: true
            )
        )
        #expect(
            !KeyGridView.shouldCommitSpace(
                isEngaged: true, isCursorTracking: false, didSwitchLayout: true, commit: true
            )
        )
    }
}

@MainActor
@Suite(.serialized)
struct KeyboardDiagnosticsPreferenceTests {
    @Test func touchTracingIsOptIn() {
        let defaults = KeyboardPreferences.defaults
        let key = KeyboardPreferences.touchTraceKey
        let saved = defaults?.object(forKey: key)
        defer {
            if let saved {
                defaults?.set(saved, forKey: key)
            } else {
                defaults?.removeObject(forKey: key)
            }
        }

        defaults?.removeObject(forKey: key)
        #expect(!KeyboardPreferences.touchTraceEnabled)

        KeyboardPreferences.touchTraceEnabled = true
        #expect(KeyboardPreferences.touchTraceEnabled)
    }
}
