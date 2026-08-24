import importlib.util
from pathlib import Path
import unittest


MODULE_PATH = Path(__file__).resolve().parents[1] / "compare-benchmark.py"
SPEC = importlib.util.spec_from_file_location("compare_benchmark", MODULE_PATH)
MODULE = importlib.util.module_from_spec(SPEC)
assert SPEC.loader is not None
SPEC.loader.exec_module(MODULE)


class CompareBenchmarkTests(unittest.TestCase):
    def test_parses_keyboard_and_transcription_markers(self):
        metrics = MODULE.parse_markers(
            """
            VocaPhoneBenchmark|metric|name=strip(\"hel\")|median_us=10.5|p95_us=14.0
            VocaPhoneBenchmark|transcription|model=small|run=1|elapsed_ms=1200|threads=4|audio_ctx=0
            VocaPhoneBenchmark|transcription|model=small|run=2|elapsed_ms=1400|threads=4|audio_ctx=0
            """,
        )
        self.assertEqual(metrics['strip("hel")']["p95_us"], 14.0)
        self.assertEqual(metrics["transcription:small"]["median_ms"], 1300.0)

    def test_regression_requires_both_thresholds(self):
        results = MODULE.compare(
            {"metric": {"median_us": 110.0}},
            {"metric": {"median_us": 100.0}},
            max_percent=5.0,
            max_absolute=20.0,
        )
        self.assertEqual(results[0]["status"], "ok")

        results = MODULE.compare(
            {"metric": {"median_us": 130.0}},
            {"metric": {"median_us": 100.0}},
            max_percent=5.0,
            max_absolute=20.0,
        )
        self.assertEqual(results[0]["status"], "regressed")

    def test_missing_current_metric_fails(self):
        results = MODULE.compare(
            {"metric": {"median_us": 100.0}},
            {
                "metric": {"median_us": 100.0},
                "transcription:model": {"median_ms": 200.0},
            },
            max_percent=15.0,
            max_absolute=0.0,
        )
        self.assertEqual(
            results[-1],
            {"name": "transcription:model", "status": "missing-current"},
        )


if __name__ == "__main__":
    unittest.main()
