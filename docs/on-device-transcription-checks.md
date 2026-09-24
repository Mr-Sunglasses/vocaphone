# On-device transcription: device checks

What only a phone can show about transcription on the phone itself: the model
being unloaded and reloaded, the app finishing a dictation from the background
or after iOS killed it, memory, and a real microphone. Run this after changing
`ios/VocaPhoneApp/Models/`, `android/app/src/main/java/com/vocahq/vocaphone/local/`,
native code, audio conditioning or transcript finishing, and after any
WhisperKit, whisper.cpp or sherpa-onnx bump.

Model tests that decode synthesized speech with the real pinned models, on a
Mac or in CI, are in review (#330, #333, #334). Once they merge, run
`just ios model-test` and `just android model-test` first; until then those
recipes do not exist. This page is for what no such test can reach.

## How to run a check

- **Speak numbered sentences.** "One, the train leaves at nine. Two, …". A
  missing stretch is then obvious in the text, and you can tell which one.
- **Clear diagnostics first** (Settings → Clear diagnostics on iPhone), and write
  down the clock time of each dictation. The export's timestamps are UTC.
- **Go past 30 seconds** in at least one dictation per run. Whisper decodes
  thirty-second windows. Both transcription bugs found in September 2026,
  one on each platform, surfaced on dictations longer than that.
- For a failure, export diagnostics straight away (iPhone), or keep
  `just android logs` running (Android). [Reading the evidence](#reading-the-evidence)
  says what to look for.

## iPhone

Select **On this iPhone** with a Whisper model, then repeat with a sherpa
model (Parakeet 110M for English). Use the oldest supported iPhone for the
memory check.

| # | Scenario | Do | Expect |
| --- | --- | --- | --- |
| 1 | Warm | Two 5 s dictations back to back from the keyboard in Notes | Both insert. The second has no `localEngineLoaded`: the model stayed loaded |
| 2 | Long | One 45–60 s dictation | Every numbered sentence, in order. Once #331 merges, also no `localWindowEmpty` in the export |
| 3 | Idle unload | Wait 11 minutes (`localEngineReleased` appears at 10), then dictate 40 s and **finish from the keyboard without opening vocaphone** | Full text. `localEngineLoaded` with `appInForeground: false` and no `operationFailed` |
| 4 | Standby ended | Let the Quick Dictation window run out (`liveActivityEnded quickDictationOff`), then tap Dictate: vocaphone opens; speak 40 s after the start cue | Full text from the cue on. Words spoken *before* the cue are not recorded, by design |
| 5 | Relaunched | Leave the phone overnight, or open several heavy apps until iOS closes vocaphone, then dictate | Full text. The export shows the keyboard's `launchingApp`, then `appStarted`, then the app's own `launchingApp` |
| 6 | Background finish | Start, switch to Safari, speak 40 s, Finish from the keyboard | Full text inserted back into the right field |
| 7 | Interruption | Take a call or invoke Siri mid-dictation | Audio before the interruption is kept and transcribed |
| 8 | Memory | The largest model you ship (Large v3) on the oldest phone, a 60 s dictation | No crash, no `JetsamEvent` for VocaPhoneApp (see below) |

## Android

Select a Whisper model (Base or Small), then repeat with Parakeet 110M on the
`full` flavor. Run it on the Pixel and on the oldest supported phone.

| # | Scenario | Do | Expect |
| --- | --- | --- | --- |
| 1 | Warm | Two 5 s dictations back to back | Both insert, the second without "Loading model" in the log |
| 2 | Long | One 45–60 s dictation | Every numbered sentence, including the one spoken around 30 s (#332) |
| 3 | Idle unload | Wait 3 minutes (the engine unloads after 2), then dictate 40 s | Full text. The log shows a fresh "Loading model" |
| 4 | Screen off | Start, lock the phone, speak 40 s, unlock, finish | Full text. The microphone foreground service keeps the recording alive |
| 5 | Memory | The largest model the app offers on the oldest supported phone (it hides models the phone lacks the memory for), 60 s | No crash, and no `lowmemorykiller` line for `com.vocahq.vocaphone` in logcat |

## Reading the evidence

### An iPhone diagnostics export

One JSON line per event, numbers and closed enums only. The lines that tell a
transcription story, in order:

```text
sessionStateChanged recording     capture started
captureStopped                    capture ended; recording length = the gap between these two
sessionStateChanged transcribing
localEngineLoaded                 only when the model had to be loaded:
                                  milliseconds, appInForeground, megabytesAvailable
localWindowEmpty                  once #331 merges: a window that held speech
                                  decoded to nothing
localEngineRetried                the first attempt failed; operationFailed just before it
                                  carries errorDomain / errorNumber
transcriptReady / readyToInsert   done
```

- **Decode time** is `readyToInsert` minus `localEngineLoaded`, or minus
  `transcribing` when nothing was loaded. With the same model and settings it
  grows with recording length, so a longer dictation that decoded faster than a
  shorter one is a reason to check its transcript against what was said. It is
  a clue, not proof: a different model, quality setting or engine changes the
  speed too. It is how the WhisperKit 1.1.0 regression (#329) was first
  noticed.
- `localEngineReleased` means the model was dropped. The next dictation pays a
  cold load, which is what scenarios 3 and 4 exercise.
- `appStarted` between two sessions means the app was relaunched, most often
  after iOS closed it.

### More from an iPhone

- **Memory kills:** list them with
  `xcrun devicectl device info files --device <udid> --domain-type systemCrashLogs`,
  then copy the `JetsamEvent-*.ips` files with `device copy from`. Each process
  in one has `name`, `rpages` and `reason`.
- **System log:** `sudo log collect --device-udid <udid> --last 1h --output vocaphone.logarchive`
  (it needs root), then open it in Console and filter by `VocaPhoneApp`.
- **The app's container** (model folders, preferences, an exported diagnostics
  file under `tmp/`) is readable with `devicectl … --domain-type appDataContainer`.
  The App Group, which holds the live diagnostics log, is not.

### Android logcat

`just android logs` follows the app. The whisper.cpp lines are tagged
`VocaPhoneWhisper`:

```text
Loading model from …                       a cold load
Transcribing <n> samples with <t> threads, beam=…, audio_ctx=…
Transcription finished in <ms> ms (status=0, segments=<k>)
```

`<n>` / 16000 is the recording length in seconds. The segment count is not a
measure of completeness: how whisper.cpp splits segments depends on its
settings, and a complete dictation can have only one or two. Check the numbered
sentences in the text instead. A non-zero `status` is a decode failure, which
the app reports as an error rather than an empty transcript.
