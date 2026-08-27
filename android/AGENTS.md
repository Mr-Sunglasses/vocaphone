# Android agent notes

Read this before changing the IME (`app/src/main/java/com/vocahq/vocaphone/ime/`).
Human setup, flavors, and release tags: [README.md](README.md).

The keyboard is a Compose `InputMethodService`. Users type on 120 Hz panels.
A frame is **8.3 ms** (16.7 ms at 60 Hz). Work that blocks the IME main thread
for a full frame reads as a stutter, not as lag.

## Pointer and drawing

A press must dirty **one key** and send **one write** to the editor.

- Send letters, shift, layer, return, and delete on **pointer down**. Space
  still commits on up so a cursor-swipe is not a space.
- If the gesture becomes a swipe, undo **only the seed letter**
  (`KeyboardReducer.undoLastCharacter`). Do not clear the whole composing word.
- Accents: commit the letter on down; on long-press up, undo then commit the
  variant. That keeps the first glyph inside the 8.3 ms budget and still
  lets a hold replace it.
- Preview is one in-tree overlay (`KeyPreviewLayer`) above the key grid. Do
  **not** open a Compose `Popup` per tap. That is `WindowManager.addView` /
  `removeView` on the down frame (often 5–20 ms) before the letter is sent.
- Do not put `Modifier.shadow` on idle keys. Pressed state is a local color
  change on that key.
- Swipe trail is a sibling `Canvas` over a `SnapshotStateList`. Never store
  trail points as `var` on the composable that builds the ~40 `KeyButton`s.
- `KeyboardLayouts.rows()` allocates a new list. Remember it by
  `(layer, returnKey, leadingPunctuation, numberRow)`. Rebuilding it on every
  composing letter prevents Compose skip.
- Per-key lambdas must be stable: `remember(key.id) { { currentOnKey.value(key) } }`
  plus `rememberUpdatedState` at the parent. `{ onKey(key) }` inline in
  `KeyboardRows` is a new object every pass and recomposes every key.
- Do not read `swipeConsumed.value` (or other shared gesture flags) during
  `KeyButton` composition. Gestures may read the `MutableState` on up.

Do not rewrite the IME in Views unless traces still show Compose pointer
and skip missing the frame after measurement.

Known leftover: each special key still has its own `pointerInput`. Do not
add more. A single parent pointer stream is the next cut if Choreographer
p95 climbs again.

## InputConnection

`getTextBeforeCursor` / `getTextAfterCursor` / `getCursorCapsMode` are
**blocking Binder calls into the app being typed into**. Measured 7–16 ms per
read on a POCO F1 typing into Messages — a whole 60 Hz frame, spent on the
other app’s main thread.

- Composing text lives in `KeyboardState.composing`. The strip uses that, not
  a fresh editor read, while a word is in progress.
- `handleCommand` skips `scheduleEditorTextRefresh()` for `SetComposingText`.
  Other commands coalesce the read at 50 ms (`EDITOR_TEXT_REFRESH_DELAY_MS`).
- Do not call `finishComposingText` when `composingRegionActive` is already
  false. That is still an IPC.
- Batch multi-call edits (`finishComposing` + `commitText`, double-space
  period) with `beginBatchEdit` / `endBatchEdit`.
- Keep `setComposingText` for letters so a suggestion can replace `hel` with
  `hello `. Do not switch letters to `commitText` without measuring Messages
  and Chrome on a phone: composing is what makes the replacement cheap.
- Caching text-before-cursor and expected selection locally is the next IPC
  cut; the 50 ms coalesced read is the reconcile, not the source of truth.

## Suggestions and swipe

- Load `en.txt`, bigrams, the emoji catalog, and `emoji/suggestions.tsv` on
  `Dispatchers.Default` in `onCreate`, never inside the first composition. The
  strip and emoji panel already render empty.
- `strip()` / `swipe()` / `similar()` run off the composition thread
  (`LaunchedEffect` + `Dispatchers.Default`). Do not move them back into
  `remember`.
- `LaunchedEffect` cancellation is cooperative. Tight 10k-word loops must
  take `shouldAbort` (checked every 128 words). Otherwise a cancelled job
  still burns CPU and fights the 120 Hz thread for cores.
- Do not key the strip effect on `editorText` while `composing` is nonempty.
  That scheduled a second scan ~50 ms after every letter.
- Swipe scoring of a messy path is **3.5 ms median / 5.5 ms p95** on a
  Nothing Phone (1). That is most of a 120 Hz frame. It stays off the pointer
  thread. Prefer `Channel.UNLIMITED` with ordered apply over `CONFLATED` so
  two swipes in a row still commit in order.

Word list, bigrams, emoji catalog: `assets/keyboard/` at the repo root, merged
into the APK via `sourceSets` in `app/build.gradle.kts`. iOS reads the same
files. Edits belong there, not in a platform-local copy.

## Dictation vs keys

`DictationState.level` updates at 10 Hz while recording. Collecting it at the
IME root recomposes the whole keyboard, including keys. Isolate it in
`DictationBar` / `MicButton` if you touch that path. The waveform
`rememberInfiniteTransition` must only exist while `isRecording`.

## Measuring

Activity-level frame metrics never see IME presses (different window). Time
the work a press actually does, on a 120 Hz phone:

```sh
# Host JVM
./gradlew :app:testFullDebugUnitTest -i \
  --tests 'com.vocahq.vocaphone.ime.KeyboardHotPathTest' \
  -Dvocaphone.benchmark=1

# Phone
./gradlew :app:connectedFullDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.keyboardBenchmark=true
```

`just keyboard-benchmark` runs the host pass and the device pass if a phone is
attached. Logcat tag: `VocaPhoneBenchmark`. Opt-in, not a CI gate — phones
differ. A 120 Hz budget is 8333 µs; report median and p95.

On 2026-08-22, Nothing Phone (1) (`A063`, 120 Hz): `strip("hel")` 579 µs
median, `swipe("tjhinl")` 3.5 ms median, reducer press 6.5 µs, Choreographer
frame gap 8.35 ms median (one vsync). Treat those as a baseline, not a
pass/fail.

## Build and devices

- JDK **21** exactly (F-Droid rebuilds on 21). `full` flavor for daily work;
  every Gradle task name includes the flavor (`assembleFullDebug`,
  `testFullDebugUnitTest`). `fdroid` flavor has no prebuilt sherpa-onnx.
- `just build` / `just run` / `just ci` from `android/`.
- WSL: USB debugging often shows up only on **Windows** `adb.exe`, not
  `/usr/bin/adb`. If `adb devices` is empty, try
  `/mnt/c/Users/<you>/platform-tools/adb.exe devices -l`. Copy APKs to a
  Windows path (`/mnt/c/Users/.../Temp/`) before `adb.exe install`; `wslpath -w`
  can mangle.
- Pixel is the baseline device in the README. 120 Hz work should also be
  felt on a 120 Hz panel (Nothing Phone 1 was used for the hot-path bench).

## Where the hot path lives

| File | Role |
|---|---|
| `ime/VocaPhoneKeyboard.kt` | Compose keyboard, gestures, preview, trail |
| `ime/VocaPhoneInputMethodService.kt` | `InputConnection`, coalesced editor reads |
| `ime/KeyboardModel.kt` | `KeyboardReducer`, composing, swipe undo |
| `ime/SuggestionEngine.kt` | Dictionary, strip, swipe, `shouldAbort` |
| `ime/LifecycleInputMethodService.kt` | ComposeView inside `InputMethodService` |
