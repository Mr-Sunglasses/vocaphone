#!/usr/bin/env python3
"""Resolve a Hugging Face model repository to per-file size and SHA-256 pins.

Both clients fetch every local model by `repository + revision + per-file
SHA-256`, and until now those pins were assembled by hand. That is the reason
adding or upgrading a model was expensive, and the reason a stale pin could sit
in the catalog unnoticed. This script is the missing tool: give it a repo and a
revision, and it prints the pins in the exact shape each platform wants.

    # Kotlin, for android/.../local/SherpaModelCatalog.kt
    tools/model-pins/pin_models.py csukuangfj/sherpa-onnx-nemo-... --format kotlin

    # JSON, for ios/VocaPhoneApp/Models/sherpa_model_pins.json
    tools/model-pins/pin_models.py csukuangfj/sherpa-onnx-nemo-... --format json

`--revision` defaults to the repository's current main commit, which is then
printed so it can be pinned; pass one explicitly to re-derive an existing pin.

SHA-256 comes from the LFS pointer where the file is stored in LFS (that *is*
the object's SHA-256, so nothing has to be downloaded). Small files -- tokens
lists, configs -- are plain git blobs whose git oid is a SHA-1 over different
bytes, so those are downloaded and hashed locally.

The output is a starting point, not the final entry: some repositories publish
several precisions of one model side by side (the 2024-07-17 SenseVoice carries
both `model.int8.onnx` and a 937 MB `model.onnx`). Pin the one the catalog
actually loads and set `sizeBytes` to the sum of what you kept --
`check_catalogs.py` verifies that sum against the files you pinned.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import sys
import urllib.error
import urllib.request

HF = "https://huggingface.co"

# What a sherpa-onnx recognizer actually opens: the graphs and the token table.
#
# An allowlist rather than a skip list, because the k2-fsa repositories carry a
# lot beside the weights -- sample audio, the export script that produced the
# graph, a LICENSE, leftover build metadata -- and it grows per repo. The phone
# downloads none of it, and each catalog entry's `sizeBytes` is the sum of the
# files it does download, so pinning any of it would both overstate the download
# and turn an unrelated upstream edit into a failed integrity check.
RUNTIME_SUFFIXES = (".onnx", ".ort", ".txt")

# Sample audio ships beside the weights in every k2-fsa repo, and it carries its
# own reference transcript -- a .txt the allowlist above would otherwise take
# for a token table.
SKIP_DIRECTORIES = ("test_wavs/",)


def _get(url: str) -> bytes:
    """Fetch one URL from Hugging Face over HTTPS, and only from there.

    Every URL here is built by prefixing the `HF` constant, so a repository name
    cannot reach another scheme -- but `urlopen` honours `file://` and `ftp://`
    among others, and this asserts the invariant rather than relying on every
    future caller preserving it. Nothing in the repository name is escaped
    either, so the check also catches a name that walks out of the API path.
    """
    if not url.startswith(f"{HF}/"):
        raise SystemExit(f"refusing to fetch {url!r}: not a {HF} URL")

    request = urllib.request.Request(url, headers={"User-Agent": "vocaphone-pin-models"})
    try:
        with urllib.request.urlopen(request, timeout=120) as response:  # noqa: S310
            return response.read()
    except urllib.error.HTTPError as error:  # pragma: no cover - network path
        raise SystemExit(f"{url}: HTTP {error.code} {error.reason}") from error


def resolve_revision(repo: str, revision: str | None) -> str:
    if revision and revision not in {"main", "HEAD"}:
        return revision
    info = json.loads(_get(f"{HF}/api/models/{repo}/revision/{revision or 'main'}"))
    return info["sha"]


def list_files(repo: str, revision: str, prefix: str, everything: bool) -> list[dict]:
    """The blobs to pin, sorted by path so the output is stable across runs.

    The tree endpoint has been observed returning a short listing -- one call
    omitted `tokens.txt` from a repository that plainly has it, and a later call
    for the same commit returned it. A pin built from a short listing is the
    worst possible output here: it looks right, it verifies against itself, and
    the model fails to load on a phone because a file nobody pinned was never
    downloaded. So the listing is cross-checked against the repository's own
    file index, which is produced a different way, and any disagreement is an
    error rather than a smaller set of pins.
    """
    url = f"{HF}/api/models/{repo}/tree/{revision}/{prefix}?recursive=1"
    entries = json.loads(_get(url.rstrip("/")))
    blobs = [e for e in entries if e.get("type") == "file"]

    info = json.loads(_get(f"{HF}/api/models/{repo}/revision/{revision}"))
    declared = {
        s["rfilename"]
        for s in info.get("siblings", [])
        if s["rfilename"].startswith(prefix)
    }
    missing = declared - {e["path"] for e in blobs}
    if missing:
        raise SystemExit(
            f"{repo}@{revision}: the tree listing is missing "
            f"{sorted(missing)}, which the repository index declares. "
            "This is a short read from the API, not an empty repository -- run again."
        )

    if not everything:
        blobs = [
            e
            for e in blobs
            if e["path"].endswith(RUNTIME_SUFFIXES)
            and not e["path"].startswith(SKIP_DIRECTORIES)
        ]
    return sorted(blobs, key=lambda e: e["path"])


def pin(repo: str, revision: str, entry: dict) -> dict:
    path = entry["path"]
    lfs = entry.get("lfs")
    if lfs and lfs.get("oid"):
        # The LFS oid is the file's SHA-256. `size` on the entry is the pointer
        # for LFS files in some API versions, so prefer the LFS size.
        return {"path": path, "size": lfs.get("size", entry["size"]), "sha256": lfs["oid"]}

    blob = _get(f"{HF}/{repo}/resolve/{revision}/{path}")
    return {"path": path, "size": len(blob), "sha256": hashlib.sha256(blob).hexdigest()}


def emit_kotlin(pins: list[dict]) -> str:
    lines = ["            files = listOf("]
    for p in pins:
        lines.append(f'                PinnedFile("{p["path"]}", {p["size"]:_}L,')
        lines.append(f'                    "{p["sha256"]}"),')
    lines.append("            ),")
    return "\n".join(lines)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("repository", help="Hugging Face repo, e.g. csukuangfj/sherpa-onnx-...")
    parser.add_argument("--revision", default=None, help="commit SHA; defaults to current main")
    parser.add_argument("--prefix", default="", help="only pin files under this directory")
    parser.add_argument(
        "--all",
        action="store_true",
        help=f"pin every file, not just {'/'.join(RUNTIME_SUFFIXES)} (use to inspect a repo)",
    )
    parser.add_argument(
        "--format",
        choices=("kotlin", "json", "table"),
        default="table",
        help="kotlin for SherpaModelCatalog.kt, json for the iOS pin manifests",
    )
    args = parser.parse_args()

    # `owner/name`, the only shape a Hugging Face model id takes. Checked here
    # because the repository is interpolated into a URL path unescaped, so a
    # name carrying `..` or a query string would reach a different endpoint
    # than the one the output claims to describe.
    if not re.fullmatch(r"[A-Za-z0-9._-]+/[A-Za-z0-9._-]+", args.repository):
        raise SystemExit(f"{args.repository!r} is not an owner/name repository id")
    if not re.fullmatch(r"[A-Za-z0-9._/-]*", args.prefix):
        raise SystemExit(f"{args.prefix!r} is not a valid path prefix")

    revision = resolve_revision(args.repository, args.revision)
    entries = list_files(args.repository, revision, args.prefix, args.all)
    if not entries:
        raise SystemExit(f"{args.repository}@{revision}: no files matched")

    pins = [pin(args.repository, revision, e) for e in entries]
    total = sum(p["size"] for p in pins)

    if args.format == "kotlin":
        print(f'            repository = "{args.repository}",')
        print(f'            revision = "{revision}",')
        print(f"            sizeBytes = {total:_}L,")
        print(emit_kotlin(pins))
    elif args.format == "json":
        print(json.dumps({"revision": revision, "files": pins}, indent=2))
    else:
        print(f"{args.repository}@{revision}")
        for p in pins:
            print(f"  {p['size']:>13,}  {p['sha256']}  {p['path']}")
        print(f"  {total:>13,}  TOTAL ({total / 1e6:.1f} MB)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
