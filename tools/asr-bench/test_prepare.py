"""Offline checks for prepare.py: nothing is downloaded."""

from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prepare  # noqa: E402


class PrepareTest(unittest.TestCase):
    def test_subset_is_spread_and_stable(self) -> None:
        items = list(range(1000))
        chosen = prepare.evenly(items, 10)
        self.assertEqual(chosen, [0, 100, 200, 300, 400, 500, 600, 700, 800, 900])
        self.assertEqual(prepare.evenly(items, 10), chosen)
        self.assertEqual(prepare.evenly(items[:3], 10), [0, 1, 2])

    def test_utterances_sort_numerically(self) -> None:
        keys = ["1089-134686-0010", "1089-134686-0002", "121-121726-0000"]
        self.assertEqual(
            sorted(keys, key=prepare.utterance_order),
            ["121-121726-0000", "1089-134686-0002", "1089-134686-0010"],
        )

    def test_wav_is_float_mono_16k(self) -> None:
        samples = [0.0, 0.5, -0.25, 1.0]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clip.wav"
            prepare.write_wav(path, samples)
            data = path.read_bytes()
        audio_format, channels, rate = struct.unpack("<HHI", data[20:28])
        self.assertEqual((audio_format, channels, rate), (3, 1, prepare.RATE))
        self.assertEqual(list(struct.unpack("<4f", data[44:])), samples)

    def test_every_download_is_pinned(self) -> None:
        for name, (url, size, digest) in prepare.ARCHIVES.items():
            self.assertTrue(url.startswith("https://"), name)
            self.assertGreater(size, 0, name)
            self.assertRegex(digest, r"^[0-9a-f]{64}$", name)


if __name__ == "__main__":
    unittest.main()
