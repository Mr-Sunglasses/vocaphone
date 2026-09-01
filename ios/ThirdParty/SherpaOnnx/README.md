# Sherpa ONNX iOS runtime

This directory vendors the official no-TTS iOS release used by VocaPhone's
Sherpa model engine.

- Release: [sherpa-onnx v1.12.34](https://github.com/k2-fsa/sherpa-onnx/releases/tag/v1.12.34)
- Asset: `sherpa-onnx-v1.12.34-ios-no-tts.tar.bz2`
- Archive SHA-256: `749498b2d44e86515357a8f0a6fdb05f4a73e790d2d3b67691a65c43aa644b89`
- ONNX Runtime: 1.17.1

The archive includes device and simulator slices. VocaPhone uses the CPU
provider first; the iOS Core ML provider is intentionally not enabled until it
has a separate accuracy and memory validation pass.

The native archives are not in git. From the repo root:

```sh
bash ios/ThirdParty/SherpaOnnx/fetch.sh
# or: just ios fetch
```

That downloads the pinned tarball, checks the SHA-256 above, and installs the
xcframeworks next to this file. Re-running is a no-op when they are already
present.
