# Contributing

SpeechLens changes should preserve the runtime invariants first, then improve
features, performance, or packaging.

## Required Local Setup

- Apple Silicon Mac.
- macOS 15.6 or newer on the development machine, as required by Xcode 26.
- Xcode 26 with Swift 6.3 or newer selected as the active developer toolchain.
- network access for initial SwiftPM dependency resolution.
- converted MLX weights for model-backed tests.

The development-host requirement is separate from the product deployment
target. SpeechLens app and CLI artifacts must continue to support Apple Silicon
Macs running macOS 14 or newer. Do not raise `.macOS(.v14)` in `Package.swift`
without an explicit compatibility decision.

## Before Opening a PR

Run the non-model test slice:

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
  -destination 'platform=macOS,arch=arm64' \
  -skipPackagePluginValidation
```

The preparation steps build the debug test bundle, install the MLX shader
library required by inference framing tests, and install the pinned
FFmpeg/FFprobe helpers required by media tests. They do not download or use
model weights. App code and `SpeechLensAppTests` are owned by Xcode; SwiftPM
continues to own libraries, CLI, WeightPort, and all non-app test targets.

For inference changes, also run the relevant model-backed tests with converted
weights:

```bash
export SPEECHLENS_TEST_WEIGHTS=/absolute/path/to/model_mlx.safetensors
Tools/prepare-test-metallib.sh --configuration release
swift test -c release \
  --skip-build \
  --disable-swift-testing \
  --filter 'WeightParityTests|AudioQualityTests|SampleRateIdentityTests'
```

## Review Rules

Reviewers should block changes that:

- introduce runtime PyTorch, CoreML, ANE, or sample-rate conversion.
- make `AudioIO` depend on MLX or model behavior.
- make `Inference` depend on UI frameworks.
- bypass model checksum validation.
- lower audio quality or performance gates without an explicit decision.
- add real audio fixtures without documented redistribution rights.

## Code Style

- Prefer Swift concurrency over callback or semaphore-based blocking.
- Use throwing APIs for recoverable failures.
- Keep module boundaries explicit.
- Keep release and model-artifact paths configurable where practical.

### Comments

Comments are contracts, not a transcript of implementation. Add one when it
preserves information that a reader cannot recover confidently from the code:

- rationale and architectural or policy boundaries;
- invariants, units, tensor layouts, ownership, and lifetime requirements;
- concurrency or `@unchecked Sendable` safety arguments;
- edge cases, fallback behavior, and surprising platform or tool behavior; or
- test-oracle choices, tolerances, and fixture exceptions.

Do not narrate the next statement, repeat a declaration or filename, number
ordinary execution steps, or retain development history in source. Prefer
clear names and smaller functions over comments that explain mechanics. Use
`MARK` sections only when they materially improve navigation in a long file.

Document APIs semantically rather than by quota. Public declarations with
non-obvious behavior need concise usage contracts; obvious properties, enum
cases, and signatures do not need prose that merely restates their names.

Keep short local contracts beside the implementation. Move benchmark tables,
rejected alternatives, and extended design rationale to the canonical topic
document and link to it from source. Measurements must identify their date,
hardware, workload, and build context, or be labeled explicitly as historical
evidence with incomplete provenance. Do not make equivalence or performance
claims stronger than the tests establish.

SPDX headers and compiler or tool directives are metadata, not explanatory
comments; preserve them exactly.

## Documentation Style

Public docs should be stable reference material. Do not put temporary work logs,
speculative performance logs, or unmerged experiment histories in this
directory. Convert those into GitHub issues, pull request notes, or short dated
decision records.

`docs/README.md` is the documentation index and `docs/architecture.md` is the
canonical cross-module overview. `Sources/*/README.md` files are short local
module contracts: responsibility, boundaries, prohibitions, and links to the
canonical public documentation. Do not maintain copied API declarations or
duplicate topic narratives in those files.
