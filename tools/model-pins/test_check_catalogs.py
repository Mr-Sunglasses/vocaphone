import json
import re
import unittest
from pathlib import Path

from check_catalogs import check_grammar

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


if __name__ == "__main__":
    unittest.main()
