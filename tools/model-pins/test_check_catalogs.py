import json
import re
import unittest
from pathlib import Path

from check_catalogs import check_bpe_vocab, check_grammar

ROOT = Path(__file__).resolve().parents[2]
KOTLIN = (ROOT / "android/app/src/main/java/com/vocahq/vocaphone/local/GrammarModelCatalog.kt").read_text()
PINS = json.loads((ROOT / "ios/VocaPhoneApp/Models/grammar_model_pins.json").read_text())
# Whichever grammar model is pinned, so a model upgrade does not break the tests.
MODEL_ID = next(iter(PINS["models"]))


def pins(**changes) -> dict:
    copy = json.loads(json.dumps(PINS))
    model = copy["models"][MODEL_ID]
    model.update(changes)
    return copy


class GrammarPinTests(unittest.TestCase):
    def test_the_checked_in_pins_agree(self):
        self.assertEqual(check_grammar(KOTLIN, PINS), [])

    def test_a_moved_revision_is_caught(self):
        problems = check_grammar(KOTLIN, pins(revision="0" * 40))
        self.assertTrue(any("revision" in p for p in problems), problems)

    def test_a_changed_digest_is_caught(self):
        changed = pins()
        changed["models"][MODEL_ID]["files"][0]["sha256"] = "0" * 64
        problems = check_grammar(KOTLIN, changed)
        self.assertTrue(any("files disagree" in p for p in problems), problems)

    def test_a_model_on_one_side_only_is_caught(self):
        renamed = {"models": {"other-tagger": PINS["models"][MODEL_ID]}}
        problems = check_grammar(KOTLIN, renamed)
        self.assertEqual(2, len(problems), problems)

    def test_a_wrong_total_is_caught(self):
        source = re.sub(r"sizeBytes = ([\d_]+)L", lambda m: f"sizeBytes = {int(m[1].replace('_', '')) + 1}L", KOTLIN)
        self.assertNotEqual(KOTLIN, source)
        problems = check_grammar(source, PINS)
        self.assertTrue(any("sum to" in p for p in problems), problems)

    def test_a_catalog_with_no_descriptor_is_caught(self):
        self.assertTrue(check_grammar("internal object GrammarModelCatalog {}", {"models": {}}))


SHERPA_PINS = json.loads((ROOT / "ios/VocaPhoneApp/Models/sherpa_model_pins.json").read_text())["models"]
VOCABULARIES = sorted((ROOT / "assets/speech").glob("*.bpe.vocab"))


class BpeVocabularyTests(unittest.TestCase):
    def setUp(self):
        self.assertTrue(VOCABULARIES, "no bundled bpe.vocab to test")
        self.path = VOCABULARIES[0]
        self.model_id = self.path.name.removesuffix(".bpe.vocab")
        self.text = self.path.read_text(encoding="utf-8")
        self.pin = SHERPA_PINS[self.model_id]

    def test_every_bundled_vocabulary_matches_its_model(self):
        for path in VOCABULARIES:
            model_id = path.name.removesuffix(".bpe.vocab")
            self.assertEqual(
                check_bpe_vocab(model_id, path.read_text(encoding="utf-8"), SHERPA_PINS.get(model_id)), []
            )

    def test_two_pieces_swapped_are_caught(self):
        lines = self.text.splitlines(keepends=True)
        lines[5], lines[6] = lines[6], lines[5]
        self.assertTrue(check_bpe_vocab(self.model_id, "".join(lines), self.pin))

    def test_a_missing_piece_is_caught(self):
        lines = self.text.splitlines(keepends=True)
        self.assertTrue(check_bpe_vocab(self.model_id, "".join(lines[:-1]), self.pin))

    def test_a_changed_score_alone_still_matches_the_tokens(self):
        # The digest checks the pieces and their order; scores are not in
        # tokens.txt, and the generator is what keeps them right.
        lines = self.text.splitlines(keepends=True)
        piece = lines[3].split("\t")[0]
        lines[3] = f"{piece}\t-99.0\n"
        self.assertEqual(check_bpe_vocab(self.model_id, "".join(lines), self.pin), [])

    def test_a_line_without_a_score_is_caught(self):
        problems = check_bpe_vocab(self.model_id, self.text.replace("\t", " ", 1), self.pin)
        self.assertTrue(any("piece<TAB>score" in p for p in problems), problems)

    def test_a_model_without_pins_is_caught(self):
        self.assertTrue(check_bpe_vocab("no-such-model", self.text, None))

    def test_a_model_without_a_token_table_is_caught(self):
        pin = {**self.pin, "files": [f for f in self.pin["files"] if f["path"] != "tokens.txt"]}
        problems = check_bpe_vocab(self.model_id, self.text, pin)
        self.assertTrue(any("tokens.txt" in p for p in problems), problems)


class TokenizerParsingTests(unittest.TestCase):
    def test_pieces_and_scores_come_out_in_id_order(self):
        import struct

        from bpe_vocab import pieces, vocabulary

        def field(number, wire, payload):
            key = bytes([number << 3 | wire])
            if wire == 2:
                return key + bytes([len(payload)]) + payload
            return key + payload

        def piece(text, score):
            return field(1, 2, field(1, 2, text.encode()) + field(2, 5, struct.pack("<f", score)) + b"\x18\x01")

        # A trainer spec (field 2) between the pieces must be skipped.
        model = piece("<unk>", 0.0) + field(2, 2, b"\x08\x01") + piece("\u2581t", -0.0) + piece("in", -3.0)
        self.assertEqual(pieces(model), [("<unk>", 0.0), ("\u2581t", -0.0), ("in", -3.0)])
        self.assertEqual(vocabulary(pieces(model)), "<unk>\t0.0\n\u2581t\t-0.0\nin\t-3.0\n")


if __name__ == "__main__":
    unittest.main()
