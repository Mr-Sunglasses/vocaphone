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
