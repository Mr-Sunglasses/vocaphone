#!/usr/bin/env bash
# Reproduce the Roman Hinglish GGML weights that android/.../LocalModelCatalog.kt pins.
#
# The catalog does not host weights. It pins a third-party GGML conversion of
# Oriserve/Whisper-Hindi2Hinglish-Apex by SHA-256, and this script is how that
# pin was — and can be — checked: it converts the official Apache-2.0
# safetensors itself and prints digests to compare against the catalog.
#
# Nothing here runs on a user's device and nothing here is a build step. It
# needs ~10 GB of disk and downloads ~1.7 GB of weights.
#
#   ./tools/hinglish/convert-apex-ggml.sh [workdir]
#
# Pins, so two people running this get the same bytes:
#   - the upstream model at an immutable commit
#   - whisper.cpp at this repo's submodule revision (the converter and the
#     quantizer both live there, and both have changed output format before)
set -euo pipefail

MODEL_REPO="Oriserve/Whisper-Hindi2Hinglish-Apex"
MODEL_REVISION="f3214eed20b4e4d4144e739982d911f87b9cb223"
WHISPER_CPP_REVISION="592feef04a1802b18cbeffd0fd0eb5d02570c2ec"
# convert-h5-to-ggml.py reads mel_filters.npz out of the openai/whisper tree.
OPENAI_WHISPER_REVISION="5f86d1d86363843179951550570367b37c5d6f78"

WORK="${1:-${TMPDIR:-/tmp}/vocaphone-hinglish-convert}"
mkdir -p "$WORK"
cd "$WORK"
echo "workdir: $WORK"

command -v uv >/dev/null || { echo "uv is required: https://docs.astral.sh/uv/"; exit 1; }
command -v cmake >/dev/null || { echo "cmake is required"; exit 1; }

# The sentinel rather than the directory: a half-installed venv from an
# interrupted run exists but cannot convert anything, and re-running the script
# has to be the fix for that rather than a no-op.
if [ ! -f .venv/.vocaphone-ready ]; then
  [ -d .venv ] || uv venv
  uv pip install --python .venv "torch" "transformers" "numpy" "huggingface_hub[cli]"
  touch .venv/.vocaphone-ready
fi
# shellcheck disable=SC1091
source .venv/bin/activate

clone_at() { # url revision dir
  [ -d "$3" ] || git clone --filter=blob:none "$1" "$3"
  git -C "$3" fetch --depth 1 origin "$2" 2>/dev/null || git -C "$3" fetch origin
  git -C "$3" checkout --detach "$2"
}

clone_at https://github.com/ggml-org/whisper.cpp.git "$WHISPER_CPP_REVISION" whisper.cpp
clone_at https://github.com/openai/whisper.git "$OPENAI_WHISPER_REVISION" openai-whisper

# Named file by file rather than by glob. The repo also carries a directory of
# demo clips, and `hf download` treats a bare pattern as a filename, so a glob
# here silently fetches either everything or nothing depending on the CLI
# version. These four are what the converter reads.
for file in config.json generation_config.json vocab.json added_tokens.json model.safetensors; do
  hf download "$MODEL_REPO" "$file" --revision "$MODEL_REVISION" --local-dir apex-hf
done

# Apex ships bfloat16 weights and the upstream converter cannot read them: it
# calls .numpy() on the tensor and torch refuses, with "Got unsupported
# ScalarType BFloat16". Upcasting to float32 at load time is the fix, and it is
# lossless — bfloat16 is a truncated float32 — so the float16 the converter
# writes is the same either way. Patched here rather than in the submodule,
# which this repository does not modify.
python3 - <<'PATCH'
from pathlib import Path
path = Path("whisper.cpp/models/convert-h5-to-ggml.py")
source = path.read_text()
original = "model = WhisperForConditionalGeneration.from_pretrained(dir_model)"
patched = original + ".float()"
if patched not in source:
    assert original in source, "upstream converter changed; re-check the bfloat16 patch"
    path.write_text(source.replace(original, patched))
PATCH

mkdir -p out
python3 whisper.cpp/models/convert-h5-to-ggml.py apex-hf openai-whisper out
mv out/ggml-model.bin out/ggml-apex-hinglish-fp16.bin

cmake -S whisper.cpp -B whisper.cpp/build -DCMAKE_BUILD_TYPE=Release \
  -DWHISPER_BUILD_TESTS=OFF -DWHISPER_BUILD_EXAMPLES=ON >/dev/null
# Upstream renamed the target from `quantize` to `whisper-quantize`; try both so
# this keeps working across a submodule bump in either direction.
cmake --build whisper.cpp/build --target whisper-quantize -j >/dev/null 2>&1 ||
  cmake --build whisper.cpp/build --target quantize -j >/dev/null
QUANTIZE="$(find whisper.cpp/build -type f -perm +111 \
  \( -name whisper-quantize -o -name quantize \) | head -1)"
[ -n "$QUANTIZE" ] || { echo "could not find the whisper.cpp quantize binary"; exit 1; }

for q in q5_0 q8_0; do
  "$QUANTIZE" out/ggml-apex-hinglish-fp16.bin "out/ggml-apex-hinglish-$q.bin" "$q"
done

echo
echo "SHA-256 (compare against LocalModelCatalog.kt / docs/hinglish-roman.md):"
for f in out/ggml-apex-hinglish-*.bin; do
  printf '%s  %s  %s\n' "$(shasum -a 256 "$f" | cut -d' ' -f1)" \
    "$(wc -c <"$f" | tr -d ' ')" "$(basename "$f")"
done
