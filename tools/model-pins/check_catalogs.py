#!/usr/bin/env python3
"""Check that the Android and iOS model catalogs still agree.

The sherpa half of the catalog is duplicated by hand across three files, and
nothing enforced the duplication. A model id present on one platform and not the
other, or the same id pinned to two different revisions, is a bug that only
shows up as a failed download on one platform.

This reads:

    android/app/src/main/java/com/vocahq/vocaphone/local/SherpaModelCatalog.kt
    ios/VocaPhoneShared/LocalModelCatalog.swift
    ios/VocaPhoneApp/Models/sherpa_model_pins.json
    ios/VocaPhoneApp/Models/local_model_pins.json

and asserts that every sherpa id exists in all three with the same repository,
revision, per-file size and SHA-256, and that each entry's `sizeBytes` is the
sum of the files it pins. Offline and fast, so it is safe in CI -- use
`pin_models.py` when you need to check the pins against Hugging Face itself.

    tools/model-pins/check_catalogs.py        # from the repository root

Exits non-zero and prints every disagreement it finds.
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

KOTLIN_SHERPA = Path("android/app/src/main/java/com/vocahq/vocaphone/local/SherpaModelCatalog.kt")
SWIFT_CATALOG = Path("ios/VocaPhoneShared/LocalModelCatalog.swift")
SHERPA_PINS = Path("ios/VocaPhoneApp/Models/sherpa_model_pins.json")
WHISPER_PINS = Path("ios/VocaPhoneApp/Models/local_model_pins.json")


def _int(text: str) -> int:
    return int(text.replace("_", ""))


def read_android() -> dict[str, dict]:
    source = KOTLIN_SHERPA.read_text()
    models = {}
    for block in re.findall(r"sherpa\((.*?)\n        \),", source, re.S):
        model_id = re.search(r'id = "([^"]+)"', block).group(1)
        models[model_id] = {
            "repository": re.search(r'repository = "([^"]+)"', block).group(1),
            "revision": re.search(r'revision = "([^"]+)"', block).group(1),
            "sizeBytes": _int(re.search(r"sizeBytes = ([\d_]+)L", block).group(1)),
            "files": {
                path: (_int(size), digest)
                for path, size, digest in re.findall(
                    r'PinnedFile\("([^"]+)", ([\d_]+)L,\s*"([0-9a-f]{64})"\)', block
                )
            },
        }
    return models


def read_ios() -> tuple[dict[str, dict], dict[str, dict]]:
    source = SWIFT_CATALOG.read_text()
    sherpa, whisper = {}, {}
    for block in re.findall(r"\.init\((.*?)\n        \),", source, re.S):
        model_id = re.search(r'id: "([^"]+)"', block).group(1)
        engine = re.search(r"engine: \.(\w+)", block).group(1)
        entry = {"sizeBytes": _int(re.search(r"sizeBytes: ([\d_]+)", block).group(1))}
        if engine == "sherpaOnnx":
            entry["repository"] = re.search(r'repository: "([^"]+)"', block).group(1)
            entry["revision"] = re.search(r'revision: "([^"]+)"', block).group(1)
            sherpa[model_id] = entry
        else:
            whisper[model_id] = entry
    return sherpa, whisper


def main() -> int:
    if not KOTLIN_SHERPA.exists():
        raise SystemExit("run this from the repository root")

    android = read_android()
    ios_sherpa, ios_whisper = read_ios()
    sherpa_pins = json.loads(SHERPA_PINS.read_text())["models"]
    whisper_pins = json.loads(WHISPER_PINS.read_text())["models"]

    problems: list[str] = []

    def compare_ids(what: str, left: set[str], right: set[str], left_name: str, right_name: str):
        for missing in sorted(left - right):
            problems.append(f"{what}: {missing} is in {left_name} but not {right_name}")
        for missing in sorted(right - left):
            problems.append(f"{what}: {missing} is in {right_name} but not {left_name}")

    compare_ids("sherpa", set(android), set(ios_sherpa), "Android", "iOS")
    compare_ids("sherpa", set(ios_sherpa), set(sherpa_pins), "the iOS catalog", "sherpa_model_pins")
    compare_ids(
        "whisperkit", set(ios_whisper), set(whisper_pins), "the iOS catalog", "local_model_pins"
    )

    for model_id in sorted(set(android) & set(ios_sherpa)):
        a, i = android[model_id], ios_sherpa[model_id]
        for field in ("repository", "revision", "sizeBytes"):
            if a[field] != i[field]:
                problems.append(f"{model_id}: {field} is {a[field]!r} on Android, {i[field]!r} on iOS")

        pinned_total = sum(size for size, _ in a["files"].values())
        if pinned_total != a["sizeBytes"]:
            problems.append(
                f"{model_id}: sizeBytes is {a['sizeBytes']} but the pinned files sum to {pinned_total}"
            )

        if model_id not in sherpa_pins:
            continue
        pin = sherpa_pins[model_id]
        if pin["repository"] != a["repository"]:
            problems.append(f"{model_id}: sherpa_model_pins repository disagrees with the catalog")
        if pin["revision"] != a["revision"]:
            problems.append(f"{model_id}: sherpa_model_pins revision disagrees with the catalog")
        pinned = {f["path"]: (f["size"], f["sha256"]) for f in pin["files"]}
        if pinned != a["files"]:
            problems.append(f"{model_id}: sherpa_model_pins files disagree with the Android PinnedFile set")

    if problems:
        print("\n".join(problems))
        print(f"\n{len(problems)} disagreement(s)")
        return 1

    print(
        f"OK: {len(android)} sherpa models agree across Android, iOS and the pin manifests; "
        f"{len(ios_whisper)} WhisperKit models pinned"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
