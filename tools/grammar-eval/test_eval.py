"""Offline tests for eval.py's scoring. No model needed.

    python3 -m unittest discover -s tools/grammar-eval -p 'test_*.py'
"""

import unittest

from eval import damaged, edits


class DamageTests(unittest.TestCase):
    def test_a_repeated_name_losing_one_occurrence_counts(self):
        self.assertEqual(["Kevin"], damaged("Kevin met Kevin at 7", "Kevin met Alex at 7"))

    def test_protected_spans_and_numbers_are_counted(self):
        self.assertEqual([], damaged("Mail jane@example.com at 7:30", "Mail jane@example.com at 7:30"))
        # The span, and the digits inside it that the word split also sees.
        self.assertEqual(["7:30", "30"], damaged("Meet at 7:30", "Meet at 7"))

    def test_nothing_lost_is_nothing(self):
        self.assertEqual([], damaged("He don't know", "He doesn't know"))


class EditTests(unittest.TestCase):
    def test_a_word_swap_is_one_edit(self):
        self.assertEqual({(1, 2, ("doesn't",))}, edits("He don't know", "He doesn't know"))

    def test_identical_text_has_no_edits(self):
        self.assertEqual(set(), edits("All good.", "All good."))


if __name__ == "__main__":
    unittest.main()
