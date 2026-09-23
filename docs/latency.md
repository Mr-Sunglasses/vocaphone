# Latency budgets

How fast VocaPhone has to feel, how to measure it, and what to do when real
work cannot fit in the budget. Check a change against this file whenever it
touches the keyboard, the mic button, capture, transcription or insertion.

## Where the numbers come from

- **0.1 s feels instant.** Past it, the user sees the app working. This comes
  from Robert Miller (1968) and Jakob Nielsen's response-time limits. Paul
  Buchheit's "100 ms rule" for Gmail says the same thing.
- **1 s keeps the train of thought.** Past it, the user notices the wait
  (Nielsen).
- **10 s is the attention limit.** Past it, the user needs progress and a way
  out (Nielsen).
- **About 400 ms is where people stay most productive.** This is the Doherty
  threshold (Doherty & Thadani, IBM, 1982).
- **One frame to draw a response to input:** 8.3 ms at 120 Hz, 16.7 ms at
  60 Hz. See [android/AGENTS.md](../android/AGENTS.md).

## Budgets

| Moment | Budget | Why |
| --- | --- | --- |
| Key press → glyph on screen | 1 frame (8.3 ms at 120 Hz) | Typing. Enforced by the keyboard benchmark |
| Any tap → visible or felt response (haptic, pressed state, spinner) | < 100 ms | Must feel instant. The result can come later; the acknowledgment cannot |
| Mic tap → listening ("speak now") | < 500 ms target on Android; iOS includes the app hop | The Doherty threshold. Includes the start cue by design |
| Stop → mic off | < 100 ms | The user has stopped talking; the mic indicator must go out right away |
| Stop → text inserted, short clip (< 10 s), on-device | < 1 s target | Keeps the user's train of thought |
| Stop → text inserted, long clip, slow phone, or gateway | Progress state within 100 ms, cancellable | Past 1 s the user needs to see work happening |
| Model download | Percentage and time remaining, cancellable | Minutes, not seconds |

The budgets for the mic hop and for transcription are **targets**, not CI
gates. Phones differ by an order of magnitude, and a Whisper decode on a
five-year-old phone will not fit in 1 s. The 100 ms acknowledgment has no
such excuse. It is always achievable because it does not depend on the work
being done.

## Show the response before the result

When work cannot finish in 100 ms, the state change still must happen within
100 ms:

- **Android keyboard mic:** a tap fires `HapticFeedbackConstants.CONFIRM`, and
  the button switches to its busy spinner on the same frame
  (`MicDictationControl.awaitingTap`). It does not wait for the controller to
  reach LISTENING or FINALIZING. Start has to wait on the foreground service,
  `AudioRecord.start()` and the cue. Finish has to wait on the capture drain
  and on closing a gateway stream. Either can take hundreds of milliseconds.
- **iOS keyboard:** a tap plays `KeyboardHaptics.shared.action()` and writes the next
  session state (`launchingApp`, `finalizing`) in the same handler. That
  state renders before any work starts.
- **Anywhere else:** if an action waits on disk, the network, a model or
  another process, show a state that says so (pressed, spinner, "Finishing…")
  before starting the wait. Do not block the main thread to avoid showing one.

## Measuring

Both apps already timestamp every dictation stage in their content-free
diagnostic log. Each builds a latency summary from that log, with median, p95
and sample count per span:

| Platform | Where | Spans |
| --- | --- | --- |
| Android | About → **Copy diagnostics**, "Latency" block (`DictationLatency`) | Tap → listening, Stop → mic off, Stop → transcript, Stop → inserted |
| iOS | Settings → Diagnostics → **Export diagnostics**, header (`DiagnosticLatency`) | Tap → recording, Stop → mic off, Stop → transcript, Stop → inserted |

This works on release builds and leaves no data on the device beyond what the
log already holds. It is not telemetry. Nothing is sent anywhere unless the
user shares the report.

To record a baseline:

1. Clear the diagnostic log.
2. Do at least 20 dictations of 3–8 s each in one app (for example Messages),
   with one engine and model.
3. Copy or export diagnostics and record the latency block below with the
   phone, OS, engine and model.

Report median and p95. A single run tells you nothing about p95.

Keystroke and frame timing have their own harnesses:
`just android keyboard-benchmark` (see [android/AGENTS.md](../android/AGENTS.md))
and the iOS keyboard's `FrameMonitor`.

Notes on accuracy:

- Android timestamps are wall-clock milliseconds. State lines are written by a
  collector, so they can land a few milliseconds after the transition.
- iOS uses `uptimeMilliseconds`, which is monotonic across the keyboard and
  the app, so a span can start in one process and end in the other.
- A span that crosses a cancel or a failure is dropped, not counted.

## Baselines

Measured values, not goals. Add a row whenever you measure; do not overwrite
an old one. Compare a change against the same phone and engine.

| Date | Phone | OS | Engine / model | Tap → listening | Stop → mic off | Stop → inserted | n |
| --- | --- | --- | --- | --- | --- | --- | --- |
| — | — | — | — | not yet measured | | | |

## Sources

- Jakob Nielsen, [Response Times: The 3 Important Limits](https://www.nngroup.com/articles/response-times-3-important-limits/)
- Robert B. Miller, "Response time in man-computer conversational transactions", AFIPS 1968
- Walter J. Doherty and Ahrvind J. Thadani, "The Economic Value of Rapid Response Time", IBM, 1982
- [Superhuman: the 100 ms rule](https://blog.superhuman.com/superhuman-is-built-for-speed/)
