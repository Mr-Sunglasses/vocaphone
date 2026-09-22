#!/usr/bin/env python3
"""Add the native libraries actually packaged in an APK to its runtime SBOM."""

import argparse
import hashlib
import json
import subprocess
import zipfile
from pathlib import Path


def complete(bom, apk, native, whisper_revision):
    root = bom["metadata"]["component"]["bom-ref"]
    root_dependencies = next(item for item in bom["dependencies"] if item["ref"] == root)
    with zipfile.ZipFile(apk) as archive:
        for path in sorted(archive.namelist()):
            if not (path.startswith("lib/") and path.endswith(".so")):
                continue
            name = Path(path).name
            provenance = native.get(name)
            if name.startswith(("libwhisper", "libggml")):
                provenance = {
                    "name": "whisper.cpp", "version": whisper_revision,
                    "source": f"https://github.com/ggml-org/whisper.cpp/tree/{whisper_revision}",
                    "license": "MIT",
                }
            # Inventory every binary, including transitive AndroidX / NDK files.
            component = {
                "type": "file", "bom-ref": path, "name": path,
                "hashes": [{"alg": "SHA-256", "content": hashlib.sha256(archive.read(path)).hexdigest()}],
            }
            if provenance:
                component.update(
                    version=provenance["version"],
                    licenses=[{"license": {"id": provenance["license"]}}],
                    externalReferences=[{"type": "vcs", "url": provenance["source"]}],
                    properties=[{"name": "vocaphone:native-project", "value": provenance["name"]}],
                )
            else:
                component["properties"] = [{
                    "name": "vocaphone:provenance-status",
                    "value": "See resolved Maven graph or NDK; not independently mapped",
                }]
            bom["components"].append(component)
            root_dependencies["dependsOn"].append(path)
            bom["dependencies"].append({"ref": path, "dependsOn": []})
    bom["metadata"]["properties"] = [{
        "name": "vocaphone:scope",
        "value": "Resolved Android runtime graph and packaged native files; excludes separately downloaded models and optional gateway",
    }]
    return bom


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("bom", type=Path)
    parser.add_argument("apk", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parent.parent
    native = json.loads((root / "tools/native-dependencies.json").read_text())
    revision = subprocess.check_output(
        ["git", "rev-parse", "HEAD:android/third_party/whisper.cpp"], cwd=root, text=True
    ).strip()
    result = complete(json.loads(args.bom.read_text()), args.apk, native, revision)
    args.output.write_text(json.dumps(result, indent=2) + "\n")
