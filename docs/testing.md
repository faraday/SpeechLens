# Testing

Whole-file fixture collection, writing, planar/interleaved conversion,
downmixing, and synchronous callback recording are test-only utilities in
`TestSupport`. Production AudioIO and MediaIO expose only bounded streaming
primitives.

SpeechLens has two test tiers:

1. Tests that do not require model weights.
2. Model-backed tests that require converted MLX weights and a packaged
   `mlx.metallib`.

Run these tests on an Apple Silicon development machine with macOS 15.6 or
newer and Xcode 26 with Swift 6.3 or newer. These are build-host requirements;
the compiled app and CLI continue to target macOS 14 or newer.

## Quick Local Tests

Run tests that do not need model weights:

```bash
Tools/prepare-test-metallib.sh --configuration debug
Tools/bootstrap-ffmpeg.sh
swift test \
  --skip-build \
  --disable-swift-testing \
  --filter 'ArchTests|AudioIOTests|MediaIOTests|CLITests|DiagnosticsTests|InferenceTests|ProcessingTests|TestSupportTests'
xcodebuild test \
  -project SpeechLens.xcodeproj \
  -scheme SpeechLens \
  -destination 'platform=macOS,arch=arm64'
```

These cover module boundaries, audio buffer behavior, FFprobe inspection,
canonical native-rate output recipes, ordered stream substitution and packet
copying, CLI weight resolution, inference settings validation, metallib
validation, model-cache verification, and playback state behavior. The
preparation steps install the debug metallib required by MLX framing tests and
the pinned FFmpeg/FFprobe helpers required by media tests. This tier does not
load model weights.

The unified media regressions use the pinned bundled helpers and cover the
committed synthetic HE-AAC M4A fixture plus dynamically generated source-adaptive
MP3, source-aware ABR-targeted AAC M4A/MOV, AAC-in-AVI rejection,
ALAC/PCM/FLAC MOV/MP4, FLAC,
and MPEG-4 MP4 transactions. The MP4 tests create video plus multiple audio
tracks, then verify selected audio replacement while packet-copying video and
other audio tracks. The HE-AAC fixture is CI-owned and must never skip for
fixture absence. MediaIO characterization tests run with normal macOS codec
service access and verify Apple AAC presentation bounds, trailing decoder
padding, stable EOF, and MOV edit-list behavior without inferring encoder delay
from waveform content. All other media inputs are generated in each test:

```bash
Tools/bootstrap-ffmpeg.sh
swift test --disable-swift-testing \
  --filter 'MediaInspectionTests|FFmpegPipeAudioSourceTests|BundledMediaRuntimeTests|AppleAACTimelineCharacterizationTests|UnifiedCodecTransactionTests|UnifiedStreamRoutingTests'
```

For a real model-backed energy-path benchmark, including phase timings, helper
invocation counts, peak RSS, and helper temporary storage:

```bash
Tools/benchmark-avi.sh \
  --input /absolute/path/input.avi \
  --output /absolute/path/output.avi \
  --weights /absolute/path/model_mlx.safetensors
```

## Full Model Tests

Set converted MLX weights:

```bash
export SPEECHLENS_TEST_WEIGHTS=/absolute/path/to/model_mlx.safetensors
```

Prepare the MLX metallib for the test bundle:

```bash
Tools/prepare-test-metallib.sh --configuration release
```

Run model-backed tests:

```bash
swift test -c release \
  --skip-build \
  --disable-swift-testing \
  --filter 'WeightParityTests|AudioQualityTests|SampleRateIdentityTests|MLXRuntimeTests'
```

Run the release performance and RSS gates from the same provisioned build:

```bash
Tools/package-local.sh --configuration release
swift test -c release \
  --skip-build \
  --disable-swift-testing \
  --filter PerformanceTests
```

## Test Targets

| Target | Purpose | Requires model weights |
| --- | --- | --- |
| `ArchTests` | static module boundary checks | No |
| `AudioIOTests` | native-rate planar streaming and format behavior | No |
| `MediaIOTests` | container policy, media descriptors, Apple AAC presentation behavior, and helper pipe lifecycle | No |
| `TestSupportTests` | shared media runtime paths plus test-only audio conversion, downmix, and callback-state helpers | No |
| `CLITests` | CLI weight path resolution | No |
| `DiagnosticsTests` | shared report schema, privacy exclusions, recovery, and failure taxonomy | No |
| `InferenceTests` | settings and metallib diagnostics | No |
| `SpeechLensAppTests` (Xcode) | workflow state, App services, menu presentation, model cache, localization, accessibility helpers, diagnostics, waveform, and playback | No |
| `ProcessingTests` | bounded scheduling, direct media transactions, timestamp rendering, native encoding, and copied user-facing streams | No |
| `WeightParityTests` | MLX layer outputs vs Python probes and B=2 vs serial B=1 parity | Yes |
| `AudioQualityTests` | output quality vs real fixtures | Yes |
| `SampleRateIdentityTests` | output sample rate equals input sample rate | Yes |
| `MLXRuntimeTests` | model-backed MLX cache and runtime isolation | Yes |
| `PerformanceTests` | throughput and peak RSS gates | Yes |

## Xcode Package Access

`SpeechLensAppTests` sets `SWIFT_PACKAGE_NAME = speechlens` in its Xcode build
settings so the test target participates in the same package access domain as
the SwiftPM modules. This allows tests to construct package-scoped types
(`MediaSourceIdentity`, `InspectedMediaJob`, `PreparedMediaJob`, etc.) without
duplicating internal construction logic or introducing test-only APIs in
production modules.

The production `SpeechLens` app target does **not** set `SWIFT_PACKAGE_NAME`.
It uses only public APIs from its dependencies. An `ArchTests` sensor enforces
this invariant by parsing the project file.

## Skip Behavior

Model-backed tests should skip instead of failing when required local artifacts
are absent. Required artifacts include:

- converted MLX weights.
- complete real fixture pairs.
- release CLI binary for the peak RSS gate.

A skipped model test means the local machine was not fully provisioned; it does
not prove model correctness. Provisioned model correctness, packaged smoke, and
performance CI use `--forbid-skips`, so a skipped selected case fails the job
after its xUnit report is written. A selected CI run that executes zero tests
also fails.

Fixture metadata and redistribution status are documented in
[Fixtures](fixtures.md).

## CI Shape

The normal CI workflow runs on macOS 26, selects Xcode 26 with Swift 6.3 or
newer, prepares the debug test metallib, runs the non-app SwiftPM tests, and
runs `SpeechLensAppTests` through Xcode alongside package smoke checks. The
deployment target remains macOS 14.
Model-correctness CI runs only when manually dispatched or invoked by the
release workflow. It downloads a pinned model artifact, verifies its SHA-256,
prepares `mlx.metallib`, runs model-backed correctness without skips, packages
the release CLI, and gates throughput and peak RSS without skips.

The independently generated PyTorch reference probes are the primary numerical
oracle for model-backed parity. Fixed Metal selective-scan tests additionally
cover deterministic B=1/B=2 behavior and reject non-16 state shapes; they do
not rely on a second in-tree Metal implementation as a reference.

Converted MLX weights are public on Hugging Face at
<https://huggingface.co/faraday/re-use-mlx> under the NVIDIA One-Way
Noncommercial License (NSCLv1). They are not gated; contributors and CI can
download the pinned revision without special Hugging Face access. See
[Model Artifacts](model-artifacts.md) for the revision, SHA-256, and license
boundary. Model-correctness CI may still use an optional `HF_TOKEN` for
Hugging Face rate limits; it is not required for authorization. Default public
CI remains the non-model slice so pull requests do not need weights or a token.
