# Sherpa ONNX Android runtime

These are the prebuilt native libraries behind the `full` flavor's Sherpa model
engine. The `fdroid` flavor drops this directory and builds without them.

- Source: [sherpa-onnx v1.13.6](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.13.6)
  (`1cb484af5e69d3c7803c1eb0b3b5ab8041e0e911`)
- ONNX Runtime: **1.28.0**, taken from
  [csukuangfj/onnxruntime-libs](https://github.com/csukuangfj/onnxruntime-libs/releases/tag/v1.28.0),
  which is the same source sherpa-onnx's own build script uses
- Archive SHA-256 (`onnxruntime-android-1.28.0.zip`):
  `7fb1d81f1fbb3e660e34baf20d8edbe5aebaa0df2793ae27d24aeade39290d1f`
- Toolchain: NDK 27.2.12479018, `android-21`, `CMAKE_BUILD_TYPE=Release`

## Why these are built here rather than downloaded

sherpa-onnx's published Android release pins ONNX Runtime 1.27.1, and the
version of ONNX Runtime matters on Snapdragon 8 Elite Gen 5 (SM8850), which is
the first Arm SoC we ship to that implements SME but **not** SME2:

- Up to and including **1.23.2** — what we shipped through 0.1.0-beta.17 —
  `MLAS_PLATFORM` installs the KleidiAI GEMM and convolution overrides whenever
  `HasArm_SME()` is true, but every ukernel those overrides call is an SME2 one
  (`..._sme2_mopa`, `..._sme2_mla`). On an SME-without-SME2 core the first
  matmul executes an instruction the CPU does not have and the process dies with
  `SIGILL`. Upstream:
  [#26377](https://github.com/microsoft/onnxruntime/issues/26377),
  [#26678](https://github.com/microsoft/onnxruntime/issues/26678) (OnePlus 15 on
  1.23.2, our exact crash), fixed by
  [#27403](https://github.com/microsoft/onnxruntime/pull/27403).
- **1.27.x** no longer crashes, but miscomputes zipformer encoders on the same
  SoC — no error, just wrong numbers
  ([sherpa-onnx#3845](https://github.com/k2-fsa/sherpa-onnx/issues/3845)).
- **1.28.0** is the first release clear of both. It detects SME (HWCAP2 bit 23)
  and SME2 (bit 37) separately and picks the matching ukernel, and it adds a
  `mlas.disable_kleidiai` session option as an escape hatch.

Rebuilding against 1.28.0 is what gets us there: `libsherpa-onnx-jni.so` imports
exactly one symbol from ONNX Runtime, `OrtGetApiBase`, and it is version-tagged
(`@VERS_1.28.0`), so the two libraries can only be replaced as a pair.

## Rebuilding

```sh
curl -LO https://github.com/csukuangfj/onnxruntime-libs/releases/download/v1.28.0/onnxruntime-android-1.28.0.zip
shasum -a 256 onnxruntime-android-1.28.0.zip   # must match the hash above
unzip -q onnxruntime-android-1.28.0.zip -d onnxruntime-1.28.0

git clone --depth 1 --branch v1.13.6 https://github.com/k2-fsa/sherpa-onnx.git
cd sherpa-onnx

export ANDROID_NDK="$HOME/Library/Android/sdk/ndk/27.2.12479018"
export PATH="$HOME/Library/Android/sdk/cmake/3.22.1/bin:$PATH"
# Without this the scripts fetch their own default, which is 1.27.1.
export SHERPA_ONNX_ONNXRUNTIME_ROOT="$PWD/../onnxruntime-1.28.0"
# Same 16 KB page alignment the whisper libraries get from CMakeLists.txt.
export LDFLAGS="-Wl,-z,max-page-size=16384"

./build-android-arm64-v8a.sh
./build-android-armv7-eabi.sh
```

The SDK's CMake 3.22.1 is on the path deliberately: several of sherpa-onnx's
vendored dependencies still declare a `cmake_minimum_required` that CMake 4
rejects.

Then copy `libonnxruntime.so` and `libsherpa-onnx-jni.so` out of each
`build-android-<abi>/install/lib/` into the matching directory here, and run
`just ci`, which checks the APK's segment alignment among everything else.

Everything else is left at the script's defaults, so these match the upstream
release in every respect but the ONNX Runtime version — TTS and speaker
diarization are compiled in even though VocaPhone only calls
`OfflineRecognizer`.

## Keeping the Kotlin bindings in step

`app/src/main/java/com/k2fsa/sherpa/onnx/` holds five files copied verbatim from
`sherpa-onnx/kotlin-api/` at the tag above. The JNI looks its config fields up
by name at runtime, so a library bump that adds a field — v1.13.6 added
`qnnConfig`, `hotwords` and `cohereTranscribe` — has to bring those files with
it or the lookup fails on a model it never used to touch.
