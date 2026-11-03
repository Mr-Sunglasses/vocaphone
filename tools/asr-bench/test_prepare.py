"""Offline checks for prepare.py: nothing is downloaded."""

from __future__ import annotations

import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))

import prepare  # noqa: E402
import vocab  # noqa: E402


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

    def test_long_clips_are_shared_between_sources(self) -> None:
        clean = [[f"1-{c}-0"] for c in range(40)]
        other = [[f"2-{c}-0"] for c in range(40)]
        picked = prepare.pick_long([clean, other], 24, lambda source, chapter: {"source": source})
        self.assertEqual([clip["source"] for clip in picked].count(0), 12)
        self.assertEqual([clip["source"] for clip in picked].count(1), 12)

    def test_a_short_chapter_is_replaced_from_the_same_source(self) -> None:
        clean = [[f"1-{c}-0"] for c in range(10)]
        other = [[f"2-{c}-0"] for c in range(10)]
        # Every even chapter is too short to make a clip.
        make = lambda source, chapter: None if int(chapter[0].split("-")[1]) % 2 == 0 else {"source": source}
        picked = prepare.pick_long([clean, other], 8, make)
        self.assertEqual([clip["source"] for clip in picked], [0, 0, 0, 0, 1, 1, 1, 1])

    def test_one_long_clip_comes_from_the_first_source(self) -> None:
        clean = [[f"1-{c}-0"] for c in range(10)]
        other = [[f"2-{c}-0"] for c in range(10)]
        picked = prepare.pick_long([clean, other], 1, lambda source, chapter: {"source": source})
        self.assertEqual([clip["source"] for clip in picked], [0])

    def test_every_download_is_pinned(self) -> None:
        for name, (url, size, digest) in prepare.ARCHIVES.items():
            self.assertTrue(url.startswith("https://"), name)
            self.assertGreater(size, 0, name)
            self.assertRegex(digest, r"^[0-9a-f]{64}$", name)


class VocabTest(unittest.TestCase):
    def test_default_sets_skip_vocab_without_say(self) -> None:
        self.assertNotIn("vocab-en", prepare.default_sets(lambda tool: None))
        self.assertIn("librispeech-clean", prepare.default_sets(lambda tool: None))
        self.assertEqual(prepare.default_sets(lambda tool: f"/usr/bin/{tool}"), list(prepare.SETS))

    def test_the_script_is_the_pinned_one(self) -> None:
        spec = prepare.vocab_spec()
        dictionary = [entry["term"] for entry in spec["terms"]]
        self.assertEqual(len(dictionary), len({t.lower() for t in dictionary}))
        for sentence in spec["sentences"]:
            self.assertTrue(vocab.expected_terms(sentence, dictionary), sentence)

    def test_a_term_is_matched_whole_and_exactly(self) -> None:
        self.assertEqual(vocab.occurrences("Anthropic's API and Anthropic", "Anthropic"), 2)
        self.assertEqual(vocab.occurrences("GitHubs and github", "GitHub"), 0)
        self.assertEqual(vocab.occurrences("bump sherpa-onnx now", "sherpa-onnx"), 1)
        self.assertEqual(vocab.occurrences("Hugging Face.", "Hugging Face"), 1)

    def test_spoken_forms_replace_the_longest_term_first(self) -> None:
        forms = {"ONNX": "onyx", "sherpa-onnx": "sherpa onyx", "kubectl": "cube control"}
        self.assertEqual(
            vocab.spoken("Run kubectl, bump sherpa-onnx and the ONNX models.", forms),
            "Run cube control, bump sherpa onyx and the onyx models.",
        )

    def test_the_clip_vocabulary_is_stable_and_holds_the_terms(self) -> None:
        dictionary = [f"Term{i}" for i in range(20)]
        first = vocab.clip_vocabulary("vocab-001", ["Term3", "Term7"], dictionary, 4)
        self.assertEqual(first, vocab.clip_vocabulary("vocab-001", ["Term3", "Term7"], dictionary, 4))
        self.assertEqual(len(first), 6)
        self.assertTrue({"Term3", "Term7"} <= set(first))
        self.assertNotEqual(first, vocab.clip_vocabulary("vocab-002", ["Term3", "Term7"], dictionary, 4))

    def test_term_hits_count_each_use(self) -> None:
        reference = "Ask Kanishk and Kanishk's team about PostgreSQL."
        self.assertEqual(vocab.term_hits(reference, "ask Kanishk about Postgres QL", ["Kanishk", "PostgreSQL"]), (1, 3))
        self.assertEqual(vocab.term_hits(reference, reference, ["Kanishk", "PostgreSQL"]), (3, 3))


if __name__ == "__main__":
    unittest.main()
