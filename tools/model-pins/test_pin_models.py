import unittest

from pin_models import is_runtime_file


class RuntimeFileSelectionTests(unittest.TestCase):
    def test_graphs_and_token_tables_are_kept(self):
        self.assertTrue(is_runtime_file("model.int8.onnx"))
        self.assertTrue(is_runtime_file("encoder.ort"))
        self.assertTrue(is_runtime_file("tokens.txt"))
        self.assertTrue(is_runtime_file("tokenizer/merges.txt"))

    def test_tokenizer_json_is_kept_by_basename(self):
        self.assertTrue(is_runtime_file("tokenizer/vocab.json"))
        self.assertTrue(is_runtime_file("tokenizer/tokenizer_config.json"))
        self.assertTrue(is_runtime_file("tokenizer.json"))

    def test_unrelated_json_is_skipped(self):
        self.assertFalse(is_runtime_file("config.json"))
        self.assertFalse(is_runtime_file("export/config.json"))
        self.assertFalse(is_runtime_file("tokenizer/tokenizer.model"))

    def test_sample_audio_directory_is_skipped(self):
        self.assertFalse(is_runtime_file("test_wavs/tokens.txt"))
        self.assertFalse(is_runtime_file("test_wavs/trans.txt"))


if __name__ == "__main__":
    unittest.main()
