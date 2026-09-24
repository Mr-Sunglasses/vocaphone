#!/usr/bin/env python3
"""Synthesize the audio the on-device model tests transcribe.

Nothing here is a recording of a person, and nothing is checked in: macOS `say`
(or `espeak-ng` where there is no `say`, as on a Linux CI runner) speaks a fixed
script, which becomes the 16 kHz mono float32 WAV the app captures, and each scenario then reshapes that audio the way a real
dictation goes wrong -- quiet for its first half, a long pause, silence. The
tests assert on the distinctive words each sentence carries rather than on exact
text, so a different voice or a model that punctuates differently still passes.

    tools/model-e2e/make_scenarios.py ios/build/model-e2e/scenarios

Writes one WAV per scenario and `scenarios.json` beside them.
"""

from __future__ import annotations

import json
import random
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path

RATE = 16_000

# Each sentence carries a word that no other sentence does, so a missing
# sentence is a missing marker. Spoken back to back, the first paragraph runs
# past 30 seconds, which is what makes a recording two decoding windows.
FIRST = [
    ("The quick brown fox jumps over the lazy dog near the river bank.", "fox"),
    ("I am checking whether the opening of this dictation survives transcription.", "transcription"),
    ("The weather today is warm and the sky is clear with a few clouds.", "weather"),
    ("Please remember to buy milk, eggs, bread and coffee on the way home.", "milk"),
    ("The meeting has been moved to Thursday afternoon at three o'clock.", "thursday"),
    ("Our train leaves from platform nine at half past seven in the morning.", "platform"),
    ("This is the final sentence and it should appear at the very end.", "final"),
]
SECOND = [
    ("After lunch I returned two novels to the public library downtown.", "library"),
    ("Take an umbrella because heavy rain is expected this evening.", "umbrella"),
    ("My appointment with the dentist was moved to next Monday.", "dentist"),
    ("We planted tomatoes and basil in the small garden behind the house.", "garden"),
    ("Do not forget to renew your passport before the trip in March.", "passport"),
    ("We watched the sunset from the hill before walking back to the car.", "sunset"),
]
# A breath between sentences, long enough that the silence splitter can cut there.
PAUSE_MS = 1200
SHORT = ("Please send the quarterly report before noon.", ["quarterly", "report", "noon"])


def speak(sentences: list[str], workdir: Path, pause_ms: int = 0) -> list[float]:
    if shutil.which("say"):
        aiff, wav = workdir / "speech.aiff", workdir / "speech.wav"
        voice = ["-v", "Samantha"] if b"Samantha" in subprocess.run(
            ["say", "-v", "?"], capture_output=True, check=True
        ).stdout else []
        text = f" [[slnc {pause_ms}]] ".join(sentences) if pause_ms else " ".join(sentences)
        subprocess.run(["say", *voice, "-r", "150", "-o", str(aiff), text], check=True)
        subprocess.run(
            ["afconvert", "-f", "WAVE", "-d", f"LEF32@{RATE}", "-c", "1", str(aiff), str(wav)],
            check=True,
        )
        return read_wav(wav)
    if shutil.which("espeak-ng"):
        wav = workdir / "speech.wav"
        pause = f'<break time="{pause_ms}ms"/>' if pause_ms else " "
        ssml = "<speak>" + pause.join(sentences) + "</speak>"
        subprocess.run(
            ["espeak-ng", "-m", "-v", "en-us", "-s", "150", "-w", str(wav), ssml],
            check=True,
        )
        return read_pcm16(wav)
    sys.exit("Needs macOS `say` or `espeak-ng` to synthesize the scenarios")


def read_pcm16(path: Path) -> list[float]:
    """A 16-bit mono WAV at any rate, linearly resampled to 16 kHz."""
    import wave

    with wave.open(str(path)) as source:
        rate, frames = source.getframerate(), source.readframes(source.getnframes())
    pcm = [value / 32_768 for value in struct.unpack(f"<{len(frames) // 2}h", frames)]
    step = rate / RATE
    out = []
    position = 0.0
    while position < len(pcm) - 1:
        index = int(position)
        fraction = position - index
        out.append(pcm[index] * (1 - fraction) + pcm[index + 1] * fraction)
        position += step
    return out


def read_wav(path: Path) -> list[float]:
    data = path.read_bytes()
    index = data.find(b"data")
    size = struct.unpack("<I", data[index + 4:index + 8])[0]
    return list(struct.unpack(f"<{size // 4}f", data[index + 8:index + 8 + size]))


def write_wav(path: Path, samples: list[float]) -> None:
    payload = struct.pack(f"<{len(samples)}f", *samples)
    header = b"RIFF" + struct.pack("<I", 36 + len(payload)) + b"WAVE"
    # Format 3 is IEEE float: one channel, 16 kHz, 4 bytes a sample.
    header += b"fmt " + struct.pack("<IHHIIHH", 16, 3, 1, RATE, RATE * 4, 4, 32)
    path.write_bytes(header + b"data" + struct.pack("<I", len(payload)) + payload)


def main() -> None:
    if len(sys.argv) != 2:
        sys.exit(__doc__)
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    rng = random.Random(7)

    # A phone's floor. eSpeak's formant voice is far easier to lose in noise
    # than a recorded one, and at the quiet scenarios' eightfold boost the
    # recognizer mishears it at a level `say` survives, so it gets a quieter
    # room. What the scenarios test is the app, not the synthesizer.
    noise = 0.002 if shutil.which("say") else 0.0006

    def room(count: int, level: float = noise) -> list[float]:
        # A phone's microphone never delivers digital silence.
        return [rng.gauss(0, level) for _ in range(count)]

    def noisy(samples: list[float], gain: float = 1.0) -> list[float]:
        return [sample * gain + rng.gauss(0, noise) for sample in samples]

    with tempfile.TemporaryDirectory() as temp:
        workdir = Path(temp)
        first = speak([text for text, _ in FIRST], workdir, PAUSE_MS)
        second = speak([text for text, _ in SECOND], workdir, PAUSE_MS)
        # No pauses at all: the window sweep needs speech under every offset.
        continuous = speak([text for text, _ in FIRST], workdir)
        opening = speak([FIRST[0][0]], workdir)
        # Spoken on its own so the long pause sits exactly between two
        # sentences, not at a guessed offset into a separate rendering.
        rest = speak([text for text, _ in FIRST[1:]], workdir, PAUSE_MS)
        short = speak([SHORT[0]], workdir)

    if len(first) < 31 * RATE:
        sys.exit(f"The first paragraph is {len(first) / RATE:.1f}s; it has to span two windows")

    first_markers = [word for _, word in FIRST]
    second_markers = [word for _, word in SECOND]
    quiet_until = 22 * RATE
    scenarios = {
        # Longer than one window: every sentence has to survive the split.
        "two_windows": (noisy(first), first_markers),
        # The regression WhisperKit 1.1.0 shipped: a window that opens on
        # quieter speech decoded to nothing, and only the rest was typed.
        "quiet_opening": (
            [s * (0.12 if i < quiet_until else 1.0) + rng.gauss(0, noise) for i, s in enumerate(first)],
            first_markers,
        ),
        # A phone held away from the mouth. The app levels this before decoding.
        "quiet_throughout": (noisy(first, gain=0.1), first_markers),
        # A long think between the first sentence and the rest.
        "long_pause": (
            noisy(opening) + room(4 * RATE) + noisy(rest),
            first_markers,
        ),
        "three_windows": (noisy(first) + room(RATE // 2) + noisy(second), first_markers + second_markers),
        # Speech with no breaks, which `LocalModelEndToEndTests` also cuts into
        # windows starting at many offsets, most of them mid-word.
        "continuous": (noisy(continuous), first_markers),
        "short_phrase": (room(RATE // 2) + noisy(short) + room(RATE // 2), SHORT[1]),
        "leading_silence": (room(3 * RATE) + noisy(short), SHORT[1]),
    }

    manifest = []
    for name, (samples, markers) in scenarios.items():
        write_wav(out / f"{name}.wav", samples)
        manifest.append({
            "name": name,
            "file": f"{name}.wav",
            "seconds": round(len(samples) / RATE, 1),
            "markers": markers,
        })
    (out / "scenarios.json").write_text(json.dumps(manifest, indent=2) + "\n")
    for entry in manifest:
        print(f"{entry['name']:<18} {entry['seconds']:>6}s  {len(entry['markers'])} markers")


if __name__ == "__main__":
    main()
