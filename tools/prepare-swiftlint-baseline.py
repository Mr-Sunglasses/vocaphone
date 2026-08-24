#!/usr/bin/env python3
"""Make a SwiftLint baseline portable across checkout locations.

SwiftLint stores baseline locations as paths relative to the process current
directory, but its matcher compares them with a slash-stripped absolute path
when the checkout is reached through a macOS /tmp symlink. Expand the checked-
in relative paths for the current checkout immediately before linting.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("baseline", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()

    entries = json.loads(args.baseline.read_text())
    for entry in entries:
        location = entry["violation"]["location"]
        file_name = location.get("file")
        if file_name and not file_name.startswith("/"):
            location["file"] = str(Path(file_name).resolve()).lstrip("/")

    args.output.write_text(json.dumps(entries, separators=(",", ":")) + "\n")


if __name__ == "__main__":
    main()
