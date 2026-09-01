#!/usr/bin/env bash
# Download the pinned sherpa-onnx iOS no-TTS xcframeworks.
# They used to live in Git LFS and blew VocaHQ's 10 GB/month bandwidth cap.
set -euo pipefail

root="$(cd "$(dirname "$0")" && pwd)"
version="v1.12.34"
asset="sherpa-onnx-${version}-ios-no-tts.tar.bz2"
url="https://github.com/k2-fsa/sherpa-onnx/releases/download/${version}/${asset}"
sha256="749498b2d44e86515357a8f0a6fdb05f4a73e790d2d3b67691a65c43aa644b89"
marker="${root}/.fetched-sha256"
device_a="${root}/onnxruntime.xcframework/ios-arm64/onnxruntime.a"

sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

if [[ -f "${device_a}" && -f "${marker}" && "$(cat "${marker}")" == "${sha256}" ]]; then
  size="$(wc -c < "${device_a}" | tr -d ' ')"
  if [[ "${size}" -gt 1000000 ]]; then
    echo "Sherpa ONNX iOS runtime already present (${version})."
    exit 0
  fi
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT
archive="${tmpdir}/${asset}"
echo "Fetching ${asset}"
curl -fsSL --retry 3 -o "${archive}" "${url}"
got="$(sha "${archive}")"
if [[ "${got}" != "${sha256}" ]]; then
  echo "SHA-256 mismatch for ${asset}" >&2
  echo "  expected ${sha256}" >&2
  echo "  got      ${got}" >&2
  exit 1
fi

tar -xjf "${archive}" -C "${tmpdir}"
src="${tmpdir}/build-ios-no-tts"
rm -rf "${root}/sherpa-onnx.xcframework" "${root}/onnxruntime.xcframework"
cp -R "${src}/sherpa-onnx.xcframework" "${root}/"
cp -R "${src}/ios-onnxruntime/1.17.1/onnxruntime.xcframework" "${root}/"
printf '%s\n' "${sha256}" > "${marker}"
echo "Installed sherpa-onnx ${version} into ${root}"
