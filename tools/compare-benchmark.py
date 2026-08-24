#!/usr/bin/env python3
"""Compare VocaPhoneBenchmark marker lines with a checked-in baseline."""

from __future__ import annotations

import argparse
import json
import statistics
import sys
from pathlib import Path


def parse_markers(text: str) -> dict[str, dict[str, float]]:
    metrics: dict[str, dict[str, float]] = {}
    transcription_runs: dict[str, list[float]] = {}
    for line in text.splitlines():
        marker = "VocaPhoneBenchmark|"
        if marker not in line:
            continue
        fields = line[line.index(marker) + len(marker) :].split("|")
        if not fields:
            continue
        kind = fields[0]
        values = {
            key: value
            for part in fields[1:]
            if "=" in part
            for key, value in [part.split("=", 1)]
        }
        if kind == "metric" and {"name", "median_us", "p95_us"} <= values.keys():
            metrics[values["name"]] = {
                "median_us": float(values["median_us"]),
                "p95_us": float(values["p95_us"]),
            }
        elif kind == "transcription" and {"model", "elapsed_ms"} <= values.keys():
            transcription_runs.setdefault(f"transcription:{values['model']}", []).append(
                float(values["elapsed_ms"]),
            )

    for name, runs in transcription_runs.items():
        metrics[name] = {
            "median_ms": statistics.median(runs),
            "runs": float(len(runs)),
        }
    return metrics


def load_baseline(path: Path) -> dict[str, dict[str, float]]:
    document = json.loads(path.read_text())
    if document.get("version") != 1 or not isinstance(document.get("metrics"), dict):
        raise ValueError(f"unsupported benchmark baseline: {path}")
    return document["metrics"]


def compare(
    current: dict[str, dict[str, float]],
    baseline: dict[str, dict[str, float]],
    max_percent: float,
    max_absolute: float,
) -> list[dict[str, object]]:
    results: list[dict[str, object]] = []
    for name, values in sorted(current.items()):
        previous = baseline.get(name)
        if previous is None:
            results.append({"name": name, "status": "missing-baseline"})
            continue
        for field, current_value in values.items():
            if field == "runs":
                continue
            previous_value = previous.get(field)
            if previous_value is None:
                results.append(
                    {"name": name, "metric": field, "status": "missing-baseline"},
                )
                continue
            delta = current_value - previous_value
            percent = (delta / previous_value * 100) if previous_value else 0.0
            regressed = delta > max_absolute and percent > max_percent
            results.append(
                {
                    "name": name,
                    "metric": field,
                    "current": current_value,
                    "baseline": previous_value,
                    "delta": delta,
                    "percent": percent,
                    "status": "regressed" if regressed else "ok",
                },
            )
    for name in sorted(set(baseline) - set(current)):
        results.append({"name": name, "status": "missing-current"})
    return results


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--input", type=Path, required=True)
    parser.add_argument("--baseline", type=Path, required=True)
    parser.add_argument("--write-baseline", action="store_true")
    parser.add_argument("--max-regression-percent", type=float, default=15.0)
    parser.add_argument("--max-regression-absolute", type=float, default=0.0)
    parser.add_argument("--json", action="store_true", help="print machine-readable output")
    args = parser.parse_args()

    current = parse_markers(args.input.read_text())
    if not current:
        print(f"No VocaPhoneBenchmark markers found in {args.input}", file=sys.stderr)
        return 2

    if args.write_baseline:
        args.baseline.parent.mkdir(parents=True, exist_ok=True)
        args.baseline.write_text(json.dumps({"version": 1, "metrics": current}, indent=2) + "\n")
        return 0

    results = compare(
        current,
        load_baseline(args.baseline),
        args.max_regression_percent,
        args.max_regression_absolute,
    )
    if args.json:
        print(json.dumps({"version": 1, "results": results}, indent=2))
    else:
        for result in results:
            if result["status"] == "missing-baseline":
                print(f"{result['name']}: missing baseline")
            else:
                print(
                    f"{result['name']} {result['metric']}: "
                    f"{result['current']:.2f} vs {result['baseline']:.2f} "
                    f"({result['percent']:+.2f}%) [{result['status']}]",
                )
    return 1 if any(result["status"] != "ok" for result in results) else 0


if __name__ == "__main__":
    raise SystemExit(main())
