#!/usr/bin/env python3
"""Offline checks for the model-test tooling, for CI jobs that cannot run it.

The model tests only run in the iOS and Android quality jobs, and a pull request
that changes nothing but `tools/model-e2e/` reaches neither. This runs in the
shared-assets job instead, with no network and no speech synthesizer:

- every `fetch_*.py` resolves every model it pins to a Hugging Face URL, a
  destination inside the output directory, a positive size and a SHA-256;
- a scenario WAV written by `make_scenarios.py` reads back sample for sample.

    tools/model-e2e/selftest.py
"""

from __future__ import annotations

import importlib
import sys
import tempfile
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from fetch_whisper import ALLOWED_PREFIX  # noqa: E402


def check_fetchers(out: Path) -> list[str]:
    problems = []
    for script in sorted(HERE.glob("fetch_*.py")):
        module = importlib.import_module(script.stem)
        plans = module.all_plans(out)
        if not plans:
            problems.append(f"{script.name}: no pinned files")
        for url, destination, size, digest in plans:
            if not url.startswith(ALLOWED_PREFIX):
                problems.append(f"{script.name}: {url} is not on {ALLOWED_PREFIX}")
            if out not in destination.parents:
                problems.append(f"{script.name}: {destination} is outside {out}")
            if size <= 0 or len(digest) != 64:
                problems.append(f"{script.name}: {destination.name} has no usable pin")
        print(f"{script.name}: {len(plans)} pinned files")
    return problems


def check_wav_round_trip(out: Path) -> list[str]:
    import make_scenarios

    samples = [((index * 37) % 200 - 100) / 128 for index in range(16_000)]
    path = out / "round-trip.wav"
    make_scenarios.write_wav(path, samples)
    back = make_scenarios.read_wav(path)
    if len(back) != len(samples) or any(abs(a - b) > 1e-6 for a, b in zip(samples, back)):
        return ["make_scenarios: a written WAV does not read back unchanged"]
    return []


def main() -> None:
    with tempfile.TemporaryDirectory() as temp:
        out = Path(temp).resolve()
        problems = check_fetchers(out) + check_wav_round_trip(out)
    for problem in problems:
        print(problem, file=sys.stderr)
    sys.exit(1 if problems else 0)


if __name__ == "__main__":
    main()
