"""Offline tests for eval.py's scoring. No model needed.

    python3 -m unittest discover -s tools/grammar-eval -p 'test_*.py'
"""

import unittest

from eval import as_typed, damaged, edits


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


class TypedTests(unittest.TestCase):
    """`as_typed` filters word edits the way `WritingCheck.offeredOnTypedText` does."""

    def test_a_mark_replacing_one_the_text_has_is_kept(self):
        self.assertEqual("Where are you going?", as_typed("Where you going.", "Where are you going?"))

    def test_a_mark_added_where_the_text_stops_is_dropped(self):
        self.assertEqual("He doesn't know", as_typed("He don't know", "He doesn't know."))
        self.assertEqual("Hi there\nBye", as_typed("Hi there\nBye", "Hi there.\nBye."))

    def test_a_mark_added_mid_text_is_kept_even_when_the_text_shrinks(self):
        self.assertEqual("Yes. I can't", as_typed("Yes I cannot not", "Yes. I can't"))

    def test_capitals_follow_the_typing_style(self):
        self.assertEqual("they were late", as_typed("they was late", "They were late."))
        self.assertEqual("I think you're right", as_typed("i think your right", "I think you're right."))
        self.assertEqual("We met. Then we left", as_typed("We met. then we left", "We met. Then we left."))
        self.assertEqual("I met john", as_typed("I met john", "I met John"))


if __name__ == "__main__":
    unittest.main()
