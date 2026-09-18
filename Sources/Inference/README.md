# Inference Module

## Responsibility

Runs the SE-Mamba mono forward pass with MLX on Metal. Inference owns model-aware
window sizing, STFT/iSTFT scaling, look-ahead, overlap-add, and final-tail
semantics. It never reads files, interprets channel layouts, or resamples.

## Boundaries

- One reusable model serializes every model-window invocation.
- Independent mono sessions retain only bounded input, overlap-add, and tail
  state.
- Processing owns physical-channel scheduling; Inference neither knows nor
  analyzes channel layouts.
- `InferenceSettings` is the source of truth for chunk duration and overlap.
- `InferenceMode.strict` is an opt-in numerical mode that selects the
  fast-bitcast-scalar fixed-16 scan; `.standard` remains the default.
- Model weights and the packaged metallib are validated before processing.

Magnitude post-processing mirrors the pinned NVIDIA RE-USE inference path:
after non-negative `expm1` reconstruction, a time frame is suppressed when more
than half of its frequency bins are zero.

STFT parameter scaling likewise uses integer division at the native sample rate
before rounding each FFT, hop, and window length upward to an even value.
Analysis and manual iSTFT synthesis both use PyTorch's periodic Hann window
(`periodic == true`).
STFT framing retains only complete windows, matching PyTorch's floor-based
`torch.stft` frame enumeration; an incomplete final hop is discarded after
intentional reflect center padding. iSTFT reconstruction is trimmed to the
original signal length so frame-count identity remains exact.

## Prohibitions

- No AppKit, SwiftUI, AudioToolbox, AudioIO, audio file I/O, or audio-format
  interpretation.
- No resampling or assumed sample rate.
- No PyTorch, CoreML, ANE, or runtime model conversion.
- Low-level SE-Mamba graph and tensor implementation types remain internal.

See [Architecture](../../docs/architecture.md),
[Inference runtime](../../docs/inference.md),
[Performance](../../docs/performance.md), and
[Kernel optimization](../../docs/kernel-optimization.md) for canonical
runtime, measurement, and kernel contracts.
