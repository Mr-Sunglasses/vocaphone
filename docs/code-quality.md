# Code quality and performance checks

VocaPhone uses fast static checks on every relevant pull request and keeps
performance measurements separate from correctness tests. Run the platform
gate for the files you changed:

```bash
just android ci       # Android build, tests, lint, and schema/page checks
just ios ci           # iOS project, build, preview, and test checks
git diff --check
```

The Android workflow additionally runs the pinned Detekt CLI with a checked-in
baseline; new warnings fail the job while existing findings remain recorded in
the baseline for gradual cleanup. The iOS workflow does the same with
SwiftLint. SwiftLint baselines are expanded to absolute paths in the runner
workspace by
`tools/prepare-swiftlint-baseline.py`, which keeps the checked-in baseline
portable across local paths and GitHub Actions.

## Measuring the hot path

The existing Android recipe produces both host-JVM and connected-device
measurements:

```bash
just android keyboard-benchmark 2>&1 | tee android/build/keyboard-benchmark.log
```

The benchmark tests emit `VocaPhoneBenchmark|...` records. Capture the output
to a file and compare it with a baseline when a fixed device and workload are
available:

```bash
python3 tools/compare-benchmark.py \
  --input android/build/keyboard-benchmark.log \
  --baseline tools/benchmarks/android-keyboard.json
```

Create or intentionally refresh a baseline with `--write-baseline`. The
comparator defaults to a 15% regression budget and also requires the absolute
threshold supplied by `--max-regression-absolute` to be exceeded. It reports
missing markers and missing baseline metrics as failures, so a broken
benchmark cannot silently pass.

Do not check in a benchmark baseline until it comes from a documented device,
OS, model, and workload. Emulator or hosted-runner timings are useful for
trend investigation, but they are not a substitute for a representative
physical-device measurement. Use Perfetto or Android Studio system tracing for
an unexplained Android regression, and Instruments/XCTest metrics for iOS
investigation; those traces remain artifacts of the investigation rather than
release-time source files.
