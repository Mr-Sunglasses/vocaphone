# Android typing keyboard plan

Implemented on the Android IME. This document is the spec that landed, not a
backlog. Long-press space to switch IMEs was dropped: Android's own keyboard
switcher already covers that, and the spacebar keeps swipe-to-move-cursor.

VocaPhone's Android IME is already a full QWERTY keyboard with dictation on top
(`VocaPhoneInputMethodService`, `KeyboardLayouts`, `VocaPhoneKeyboard`). The
original Android plan treated that keyboard as a way to get a microphone into
any text field. The layout is now what people type on, and it is missing the
controls a daily driver needs.

## What the keyboard does today

Four layers: letters, numbers, symbols, emoji. Each layer is four rows of 48 dp
keys plus a 52 dp dictation bar (logo, language, style, mic).

Already in place:

- Shift, caps lock on double-tap, and sentence capitalization after `.` `!` `?`
- Number and symbol layers, plus an editor-aware return key (Go, Search, Send, Done)
- Email `@` or URI `/` in the comma slot when the field asks for it
- Delete-key repeat
- Character popups while a key is held
- Spacebar swipe to move the cursor
- Haptics
- System light/dark through `VocaPhoneTheme`
- Password fields hide dictation

Missing or awkward, matching the notes in this request:

- No number row above QWERTY
- Key height is hardcoded (`48.dp` in `KeyboardRows`)
- No suggestion strip
- No clipboard paste chip
- Emoji layer is 30 hardcoded glyphs: no search, recents, or categories
- Bottom row is heavier on the left, so the spacebar sits right of center
- Globe key calls `switchToNextInputMethod` or the system picker
- No long-press accent popovers
- No double-space period

Settings cover gateway, on-device models, language, style, microphone, and
retention. There is no Keyboard section.

## Privacy boundary

`docs/Plan-Android.md` says the IME does not scrape editor contents and does not
use the clipboard as a way to insert dictation. That stays. Dictation still
commits through `InputConnection.commitText` and still refuses password fields.

Two requested features touch data the keyboard currently ignores.

Next-word suggestions need a short look behind the cursor
(`getTextBeforeCursor`), or they can only guess from keys this IME just
committed. A clipboard chip needs `ClipboardManager` while the input view is
showing. Neither is an accessibility-service scrape, and neither is clipboard
insertion of transcripts. Both should stay on-device, stay off in sensitive
fields, never go in logs, and get a paragraph in `docs/privacy.md` if they ship.

## Work to do

### Number row

Add `numberRowEnabled` to `SettingsRepository`, default off.

When on, `letterRows` prepends `1234567890`. The numbers and symbols layers stay
as they are. Keyboard settings gets a switch.

Long-press digits on the QWERTY row (q=1, w=2, …) is a reasonable extra when the
row is off. Skip it unless the row lands easily. The toggle is the request.

### Keyboard height

Add `keyboardHeight` with Compact, Default, and Tall. Map those to key heights
around 42, 48, and 56 dp. Scale the dictation bar a little so it does not look
stranded on Tall.

`PreferencePanelShell` is currently a hardcoded `207.dp`. It has to follow the
key area, or the language and style sheets will look like a different keyboard.

Gboard lets you drag the top edge. That is more code than a three-step control.
Skip the handle.

### Suggestions

A strip of up to three chips between the dictation bar and the keys. Idle with
nothing to show: hide the strip so the keyboard does not grow for empty chrome.
While composing a word: prefix completions. After a finished word: next-word
guesses.

Keep the implementation small:

- Put the current word in `setComposingText` instead of committing every
  character. `KeyboardReducer` stays pure; the IME decides composing vs commit.
- Ship a frequency-sorted English word list as an asset (about 10k words) and
  match prefixes in memory. No on-device neural model, no gateway round trip, no
  new Gradle dependency.
- Next word: a small static bigram table (last word → top continuations). When
  Suggestions is on and the field is not sensitive, read at most about 32
  characters before the cursor so a sentence started in another keyboard still
  works. If that read is rejected in review, fall back to words this IME typed
  in the current editor session only.
- No autocorrect in this pass. A wrong replacement is worse than a missed letter.

Default: on. Forced off in password and PIN fields. One switch in Keyboard
settings.

This is English QWERTY only. It will not match Gboard. Gboard's strip is a large
language model; this is a word list and a bigram table. That is enough to stop
the keyboard feeling mute. Do not block on 27 dictionaries.

### Clipboard chip

While the input view is shown, if the primary clip is text, show a Paste chip on
the suggestion strip with a short preview.

Tap commits the clip through `InputConnection`, same path as typed text. Do not
keep a clipboard history. Do not read the clipboard when the keyboard is hidden.
Do not show the chip in sensitive fields. Do not use the clipboard to deliver
dictation.

Android 12+ toasts some clipboard reads. The selected IME is usually exempt
while its input view is showing; confirm that on a physical device. If a toast
appears on every keyboard open, show an unlabeled "Paste copied text" chip from
`ClipDescription` only, and read the bytes on tap.

### Emoji panel and search

Replace the 30-emoji grid with a panel that occupies the same key area:

- Search field on top, matching Unicode CLDR short names / annotations locally
- Category tabs: smileys, people, animals, food, travel, activities, objects,
  symbols, flags
- Recents first, stored in DataStore, capped around 30
- Vertical scroll, with ABC / space / delete / return pinned at the bottom

Generate the catalog from Unicode `emoji-test` plus CLDR annotations into a
repo file (JSON or Kotlin). Do not add an emoji SDK, GIFs, stickers, or Emoji
Kitchen.

Skin-tone modifiers on long-press can follow once the catalog exists. They are
not required to call the panel done.

### Spacebar centering and the globe key

The bottom row in `utilityRow` is:

`?123` (1.2) + emoji (0.9) + comma (0.8) + globe (0.95) + space (3.25) +
period (0.8) + enter (1.45)

Weight left of space: 3.85. Weight right: 2.25. Four gaps on the left, two on
the right. That is why the spacebar sits right of center.

Remove `KEYBOARD_SWITCH` from every layer. Android already exposes a keyboard
picker in the navigation bar when more than one IME is enabled
(`method.xml` already sets `supportsSwitchingToNextInputMethod`). Do not add a
long-press-space switcher; swipe-on-space stays cursor movement.

After the globe is gone, give `?123` and Enter the same weight, and comma and
period the same weight. Recheck visual center on a device. If the emoji key
still shoves space right, shrink that key rather than adding spacers.

### Themes

Out of scope. Light and dark already follow the system (`VocaPhoneTheme`). A
theme picker is a lot of palette work for little typing benefit.

## Gboard features, keep or cut

Ship in this pass:

- Number row toggle
- Height Compact / Default / Tall
- Suggestion strip (current word and next word, local lists)
- Clipboard paste chip (current clip only)
- Emoji categories, recents, and search
- Remove globe, rebalance spacebar
- Double-space to period

Worth doing in the same pass if the layout files are already open:

- Long-press accent popovers on letters (`e` → é è ê ë, and the rest of the
  usual Western European set). The typing layout is English QWERTY while
  dictation offers many languages. Without accents, typed French, Spanish, or
  German is painful. This is a static map on `CHARACTER` keys, not a new
  subsystem.

Cut. Gboard has them; they do not belong here:

- Glide / swipe typing
- Autocorrect and grammar
- Clipboard history with pins
- GIFs, stickers, bitmoji, Emoji Kitchen
- Search, translate, and Google account features
- One-handed mode, floating or split keyboard
- Custom color themes
- Keypress sound
- On-device neural language models
- Number-row long-press alternatives, unless the number row itself is deferred

## Where the code goes

Mostly `android/app/src/main/java/com/vocahq/vocaphone/ime/` and `settings/`.
Companion UI is a new Keyboard section in `SettingsScreen.kt`.

New small types, not new modules:

- Fields on `VocaPhoneSettings`: number row, height, suggestions, clipboard chip
- `SuggestionEngine` as a pure function over prefix + previous word + word
  list, unit-tested
- `EmojiCatalog` generated data plus a filter function, unit-tested
- Clipboard listener in `VocaPhoneInputMethodService` for the input-view
  lifetime only

Tests to extend: `KeyboardLayoutsTest`, `KeyboardReducerTest`, plus new tests
for suggestions and emoji search. `./gradlew assembleDebug testDebugUnitTest
lintDebug` stays the gate. Physical-device checks still required for clipboard,
height, IME switch, and the spacebar gesture.

When this ships (not in this plan-only change), update `docs/Plan-Android.md`,
`docs/privacy.md`, and `android/README.md`.

## Order after approval

Sequential PRs, not one dump.

1. Layout: drop globe, rebalance the bottom row,
   height setting, number row, double-space period, Keyboard settings section.
2. Emoji panel: catalog, categories, recents, search.
3. Clipboard paste chip on the suggestion strip.
4. Suggestions: composing text, word list, next-word bigrams, strip UI.
5. Accent long-press if it did not land in PR 1 or 2.

PR 1 is the "keyboard feels wrong" work. PR 4 is the one that changes the
privacy wording.

## Defaults unless review changes them

- Number row: off
- Height: Default (current 48 dp)
- Suggestions: on, English lists only, no autocorrect
- Clipboard chip: on
- Globe key: removed; Android's keyboard switcher still changes IMEs
- Themes: untouched
- Next-word may call `getTextBeforeCursor(32)` when Suggestions is on and the
  field is not sensitive
- Accent long-press: include with PR 1 or 2
- iOS keyboard: not part of this work

## What review needs to decide

- Whether suggestions may call `getTextBeforeCursor`
- Whether the globe key can go without a replacement key on the board
- Whether accents belong in the first implementation wave
- Anything from the cut list that should actually ship
