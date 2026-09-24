#!/usr/bin/env python3
"""Download one pinned whisper.cpp model for the Android model tests.

The id, size and SHA-256 come from the Android catalog itself
(`LocalModelCatalog.kt`), so the test decodes the bytes a phone would, and a
changed pin changes what the test downloads. A file already present with the
right digest is not fetched again, so a CI cache of the output is safe to reuse.

    tools/model-e2e/fetch_ggml.py base-q8_0 android/build/model-e2e

Prints the path of the model file. `--catalog <file>` reads the pins from another
copy of `LocalModelCatalog.kt` (CI fetches the pin a pull request replaced, to
compare against). With `--changed-since <old catalog>`, prints instead the ids
whose pin differs from that copy, so CI can decode with every re-pinned model.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from fetch_whisper import fetch

CATALOG = (
    Path(__file__).resolve().parents[2]
    / "android/app/src/main/java/com/vocahq/vocaphone/local/LocalModelCatalog.kt"
)


def pins(source: str) -> tuple[str, dict[str, tuple[int, str]]]:
    """The base URL every model shares, and each model's (size, sha256)."""
    repository = re.search(r'WHISPER_REPOSITORY = "([^"]+)"', source).group(1)
    revision = re.search(r'WHISPER_REVISION = "([^"]+)"', source).group(1)
    models = {
        match.group(1): (int(match.group(2).replace("_", "")), match.group(3))
        for match in re.finditer(
            r'model\(\s*"([^"]+)",\s*"[^"]*",\s*([\d_]+)L,\s*"([0-9a-f]{64})"', source
        )
    }
    return f"https://huggingface.co/{repository}/resolve/{revision}/", models


def plan(model_id: str, out: Path, catalog: Path = CATALOG) -> list[tuple[str, Path, int, str]]:
    """The one file a model needs, as (url, destination, size, sha256)."""
    base, models = pins(catalog.read_text())
    if model_id not in models:
        sys.exit(f"{model_id} is not a pinned whisper.cpp model in {catalog.name}")
    size, digest = models[model_id]
    name = f"ggml-{model_id}.bin"
    return [(base + name, out / name, size, digest)]


def all_plans(out: Path) -> list[tuple[str, Path, int, str]]:
    """Every pinned model's file; `selftest.py` checks them offline."""
    return [entry for model_id in pins(CATALOG.read_text())[1] for entry in plan(model_id, out)]


def changed_since(old_catalog: Path) -> list[str]:
    old_base, old_models = pins(old_catalog.read_text())
    base, models = pins(CATALOG.read_text())
    return [
        model_id for model_id, pin in models.items()
        if base != old_base or old_models.get(model_id) != pin
    ]


def main() -> None:
    if len(sys.argv) == 3 and sys.argv[1] == "--changed-since":
        print("\n".join(changed_since(Path(sys.argv[2]))))
        return
    arguments = sys.argv[1:]
    catalog = CATALOG
    if len(arguments) == 4 and arguments[0] == "--catalog":
        catalog, arguments = Path(arguments[1]), arguments[2:]
    if len(arguments) != 2:
        sys.exit(__doc__)
    model_id, out = arguments[0], Path(arguments[1])
    for entry in plan(model_id, out, catalog):
        fetch(*entry)
    print(entry[1])


if __name__ == "__main__":
    main()
