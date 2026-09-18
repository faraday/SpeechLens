# SpeechLens Documentation

This directory contains the public documentation for SpeechLens. Its native
Swift and MLX runtime executes the fixed 30-block RE-USE SE-Mamba architecture
through specialized Metal kernels. Release-mode streaming enhancement measured
2.3×–6.6× real-time speed on an M1 Max while retaining exact sample rate and
frame count. The documentation is written for users, contributors, and release
maintainers.

## Start Here

### Use SpeechLens

| Goal | Document |
| --- | --- |
| Install the app or run the CLI | [Project README](../README.md) |
| Supported inputs, outputs, codecs, and containers | [Media Formats](media-formats.md) |
| Model download, checksums, conversion, and license | [Model Artifacts](model-artifacts.md) |
| Local processing and optional diagnostics | [Telemetry](telemetry.md) |
| Audio demo listening samples and manifest | [Demo Manifest](assets/demo/README.md) |

### Understand or Contribute

| Topic | Document |
| --- | --- |
| Runtime architecture and module boundaries | [Architecture](architecture.md) |
| Streaming inference, model layout, and STFT framing | [Inference Runtime](inference.md) |
| Single FFmpeg media engine and frozen Processing ownership | [Media boundary](media-boundary.md) |
| Supported media input/output formats | [Media Formats](media-formats.md) |
| Unified subprocess media engine and helper lifecycle | [FFmpeg media engine](ffmpeg-backend.md) |
| Serial channel-preserving processing | [Multichannel Processing](multichannel-processing.md) |
| Model weights, conversion, checksums, and licensing | [Model Artifacts](model-artifacts.md) |
| Test targets, local commands, CI behavior | [Testing](testing.md) |
| Audio quality expectations and fixture policy | [Audio Quality](audio-quality.md) |
| Audio fixture metadata and redistribution status | [Fixtures](fixtures.md) |
| Performance gates and measurement rules | [Performance](performance.md) |
| Telemetry consent, privacy, and payload contract | [Telemetry](telemetry.md) |
| Sentry auditing, symbolication, QA, and dashboards | [Sentry Operations](sentry-operations.md) |
| Metal kernel design and profiling rationale | [Kernel Optimization](kernel-optimization.md) |
| Packaging, signing, notarization, release checks | [Release Packaging](release-packaging.md) |
| Contributor rules and code review expectations | [Contributing](../CONTRIBUTING.md) |
| Pre-publication maintainer checklist | [Publication Checklist](publication-checklist.md) |

## Project Constraints

SpeechLens is an Apple Silicon speech-enhancement application and CLI. Runtime
inference runs through MLX on Metal with specialized kernels for the supported
RE-USE SE-Mamba layout. The runtime path does not use Python, PyTorch, CoreML,
ANE, or CPU/GPU copy-heavy inference frameworks. An opt-in Strict Mode selects
a numerically tighter selective-scan variant; see
[Kernel Optimization](kernel-optimization.md) and
[Audio Quality](audio-quality.md#phase-fidelity).

The strongest project invariant is sample-rate identity:

```text
output.sampleRate == input.sampleRate
```

SpeechLens must not downsample, upsample, or otherwise convert the audio sample
rate. The model achieves sample-rate invariant behavior by scaling STFT and
iSTFT parameters from the input sample rate.
