import UIKit
import Testing

/// The keyboard's language menu. A flat list of 27 was unusable on a surface this
/// cramped, so the top level stays short however many languages exist.
@MainActor
struct LanguageMenuTests {
    private func bar() -> DictationBarView {
        DictationBarView(
            metrics: .resolved(for: UITraitCollection { $0.verticalSizeClass = .regular }),
            palette: KeyboardPalette(isDark: false)
        )
    }

    private func reset(recents: [TranscriptionLanguage] = [], languages: Set<String> = [], detects: Bool = false) {
        KeyboardPreferences.recentTranscriptionLanguages = recents
        KeyboardPreferences.modelLanguages = languages
        KeyboardPreferences.modelDetectsLanguage = detects
    }

    private func titles(_ menu: UIMenu) -> [String] {
        menu.children.flatMap { element -> [String] in
            if let inline = element as? UIMenu, inline.options.contains(.displayInline) {
                return inline.children.compactMap { ($0 as? UIAction)?.title }
            }
            if let submenu = element as? UIMenu { return ["\(submenu.title) ›"] }
            return [(element as? UIAction)?.title].compactMap { $0 }
        }
    }

    @Test func theTopLevelStaysShortRatherThanListingEverything() {
        reset(recents: [.hindi, .english])
        let menu = bar().makeLanguageMenu(
            selected: .automatic,
            key: .current(selected: .automatic)
        )
        let top = titles(menu)
        #expect(top.count < 6, "top level should stay glanceable, got \(top.count): \(top)")
        #expect(top.first == "Automatic")
        #expect(top.contains("Hindi"))
        #expect(top.contains("All languages ›"))
        // Everything not promoted is still reachable, just one level down.
        #expect(!top.contains("Assamese"))
    }

    @Test func theSubmenuHoldsEveryLanguageNotPromoted() {
        reset(recents: [.hindi])
        let menu = bar().makeLanguageMenu(selected: .automatic, key: .current(selected: .automatic))
        let submenu = menu.children.compactMap { $0 as? UIMenu }
            .first { !$0.options.contains(.displayInline) }
        let all = (submenu?.children.compactMap { ($0 as? UIAction)?.title }) ?? []
        #expect(all.contains("Assamese"))
        // Promoted entries are not duplicated below.
        #expect(!all.contains("Hindi"))
        #expect(!all.contains("Automatic"))
    }

    /// The selection is the one entry the user is looking for, even if it was
    /// never recorded as recent — a fresh install with a stored language.
    @Test func theCurrentSelectionIsAlwaysPromoted() {
        reset(recents: [])
        let menu = bar().makeLanguageMenu(selected: .tamil, key: .current(selected: .tamil))
        #expect(titles(menu).contains("Tamil"))
    }

    /// A greyed-out shortcut is worse than no shortcut: it spends one of very few
    /// visible rows on something that cannot be chosen.
    @Test func recentsTheModelCannotHonourAreNotPromoted() {
        reset(recents: [.hindi], languages: ["en"], detects: false)
        let menu = bar().makeLanguageMenu(selected: .automatic, key: .current(selected: .automatic))
        #expect(!titles(menu).contains("Hindi"))
    }

    /// The gateway's model can change without the selection changing, and that
    /// flips which entries are usable. Keying the cache on the selection alone
    /// left the keyboard offering languages the app had already ruled out.
    ///
    /// Coverage is what the key tracks, since coverage is what decides a row.
    /// Auto-detection is not in it any more: it changes what the choice means,
    /// not which rows exist, and it never appears in this menu.
    @Test func theCacheKeyNoticesAModelChange() {
        reset(languages: ["en"], detects: false)
        let before = DictationBarView.LanguageMenuKey.current(selected: .automatic)
        KeyboardPreferences.modelLanguages = ["en", "hi"]
        let after = DictationBarView.LanguageMenuKey.current(selected: .automatic)
        #expect(before != after)
    }
}

struct RecentLanguageTests {
    @Test func recentsAreMostRecentFirstDedupedAndCapped() {
        KeyboardPreferences.recentTranscriptionLanguages = []
        for language in [TranscriptionLanguage.hindi, .english, .tamil, .bengali] {
            KeyboardPreferences.noteTranscriptionLanguageUse(language)
        }
        #expect(
            KeyboardPreferences.recentTranscriptionLanguages == [.bengali, .tamil, .english]
        )

        KeyboardPreferences.noteTranscriptionLanguageUse(.english)
        #expect(KeyboardPreferences.recentTranscriptionLanguages.first == .english)
        #expect(KeyboardPreferences.recentTranscriptionLanguages.count == 3)
    }

    /// Automatic is always shown first anyway, so recording it would spend one of
    /// three scarce slots on a duplicate.
    @Test func automaticIsNeverRecorded() {
        KeyboardPreferences.recentTranscriptionLanguages = []
        KeyboardPreferences.noteTranscriptionLanguageUse(.automatic)
        #expect(KeyboardPreferences.recentTranscriptionLanguages.isEmpty)
    }
}
