# Audio Quality

Audio quality checks combine structural invariants, objective regression tests,
and manual listening criteria.

## Structural Invariants

Every enhanced output must satisfy these four criteria. The assertion names are
the executable sensors in
[`AudioQualityTestHelpers.swift`](../Tests/AudioQualityTests/AudioQualityTestHelpers.swift).

| # | Criterion | Tolerance | Assertion |
| ---: | --- | --- | --- |
| 1 | output sample rate equals input sample rate | zero | `assertSampleRatePreserved` |
| 2 | output frame count equals input frame count | zero | `assertFrameCountPreserved` |
| 3 | no sample has an absolute value greater than `1.0` | zero violations | `assertNoClipping` |
| 4 | no output sample is NaN or infinite | zero violations | `assertNoNaNOrInf` |

No violations are allowed. A single mismatch, invalid sample, or out-of-range
sample fails the quality gate.

The sample-rate invariant is not negotiable. SpeechLens must not hide sample
rate conversion inside file I/O, STFT setup, model execution, or writing.

## Objective Quality Gate

Real fixtures contain `input.wav` and `expected.wav`. Model output is compared
with both the expected reference signal and the noisy input baseline. This composite
quality gate requires the enhanced output to preserve speech-active spectral
cues and not meaningfully regress from that baseline.

Sample-domain SNR is deliberately not used for this comparison: noisy input and
the reference differ at the sample level by construction, while small phase
or gain differences can dominate a sample error without representing lost
speech intelligibility.

### Spectral analysis

The quality oracle is implemented with Accelerate rather than MLX, keeping the
test measurement independent from the inference runtime. It uses:

- a Hann-windowed magnitude STFT;
- the first power-of-two FFT size covering approximately 32 ms, starting at 256
  samples and capped at 4096 samples;
- a hop of one quarter of the FFT size, giving 75% overlap;
- log-magnitude spectra; and
- only reference frames whose energy is within 40 dB of the reference peak.

At least four speech-active frames are required. Per-frame Pearson correlation
measures spectral-envelope shape; mean log-spectral distance (LSD) measures the
remaining magnitude difference in decibels. Centering each frame's log spectrum
makes Pearson correlation insensitive to uniform offsets such as overall gain;
it remains sensitive to spectral-shape changes introduced by noise or filtering.

### Acceptance thresholds

All four checks below must pass for every discovered real fixture:

| Check | Required result |
| --- | ---: |
| enhanced/reference mean frame correlation | at least `0.50` |
| enhanced/reference mean LSD | at most `12.0 dB` |
| correlation relative to noisy baseline | no more than `0.03` lower |
| LSD relative to noisy baseline | no more than `1.0 dB` higher |

The absolute limits reject output that no longer resembles the reference. The
baseline-relative limits reject an enhancer that damages speech cues even when
it happens to remain inside the broad absolute limits. Signal lengths are
defensively aligned to the shortest of output, reference, and baseline for this
metric; frame-count preservation remains a separate zero-tolerance invariant.

The tests also write outputs under `TestResults/AudioQuality/` for manual
inspection when the local run is configured with fixtures and model weights.
The test uses ten-second chunks by default and accepts a positive finite
override through `SPEECHLENS_AUDIO_QUALITY_CHUNK_SECONDS`.

## Research-Grade Metrics

The CI gates above are production safety boundaries. Separate research
campaigns evaluated SpeechLens against NVIDIA RE-USE reference outputs and
concurrent implementations using standard speech-enhancement metrics on the
URGENT-2025 corpus.

### Evaluated metrics

| Category | Metrics |
| --- | --- |
| Intrusive (clean reference required) | PESQ, ESTOI, SDR, MCD, LSD |
| Non-intrusive (no reference needed) | DNSMOS, NISQA, UTMOS |

### Headline results on URGENT-2025 clean-reference pairs (n=20)

| Metric | SpeechLens | ORT-MLX | NVIDIA reference |
| --- | ---: | ---: | ---: |
| PESQ (↑) | 1.8854 | 1.8804 | 1.8566 |
| ESTOI (↑) | 0.6907 | 0.6906 | 0.6897 |
| SDR (dB, ↑) | 5.4070 | 5.3957 | 4.9210 |
| MCD (dB, ↓) | 5.0678 | 5.0750 | 5.1406 |
| LSD (dB, ↓) | 4.0624 | 4.0644 | 4.1522 |

### Non-intrusive results on URGENT-2025 blind subset (n=50)

| Metric | SpeechLens | ORT-MLX | NVIDIA reference |
| --- | ---: | ---: | ---: |
| DNSMOS (↑) | 3.1910 | 3.1908 | 3.1495 |
| NISQA (↑) | 4.2517 | 4.2540 | 4.0952 |
| UTMOS (↑) | 2.9631 | 2.9645 | 2.8997 |

SpeechLens and ORT-MLX are closely matched on all three non-intrusive metrics;
both consistently score above the stored NVIDIA reference.

These metrics support feasibility and cross-implementation equivalence. They
do not claim perceptual superiority or population-representative statistical
equivalence. No controlled listening study was conducted.

## Phase Fidelity

A model port can achieve near-perfect waveform RMSE while failing phase
tolerance. On a 5-second 44.1 kHz diagnostic, the native production baseline
has a waveform relative RMSE of only 1.10 × 10⁻⁵ against the PyTorch/CUDA
reference, yet its maximum wrapped phase error reaches **0.0106 radians**
(25 spectral bins exceeding the 0.0013 rad engineering tolerance).

The root cause is the `fast::exp` function used for the decay term
`exp(Δₜ A)` in the selective-scan recurrence. Near-origin phase-head
coordinates amplify small Cartesian errors by ~2800× through the
`atan2(y, x)` readout (gradient norm `1/r` with `r ≈ 3.56 × 10⁻⁴`).

Replacing decay-exponential arithmetic with the fast-bitcast-scalar candidate
reduces maximum phase error to **0.0011 radians** (0 failing bins) while
retaining faster-than-real-time throughput (RTF 0.334 on 70 URGENT files).

Intermediate tensor injection diagnostics confirmed the error enters the
decoder from upstream computation in the Mamba stack, not from the phase
decoder itself.

See [Kernel Optimization](kernel-optimization.md) for the fast-bitcast-scalar
polynomial specification.

## Amplitude Range Observations

In the 73-fixture deployment campaign, 71 of 73 outputs passed the
nominal [-1.0, 1.0] amplitude range check. Two clean-reference files
(`fileid_384` and `fileid_936`) exceeded the nominal range in all tested
engines (SpeechLens, ORT-MLX, and NVIDIA reference). ORT-MLX recorded peaks
of 1.0437 and 1.1282. These outputs are left unclipped in the published
evidence.

## Fixture Policy

Real fixtures are redistributable only if the repository can document their
source and permission. For each public real fixture, record:

- source or creator.
- license or written permission.
- whether speech content contains personal or sensitive information.
- SHA-256 of `input.wav` and `expected.wav`.
- sample rate, channel count, duration, and intended degradation.

If redistribution rights are unclear, do not publish the fixture. Keep the test
able to skip missing fixtures and provide instructions for maintainers to supply
private fixtures locally.

See [Fixtures](fixtures.md) for the current fixture inventory, hashes, technical
metadata, and publication status.

## Synthetic Fixtures

Synthetic fixtures are appropriate for structural edge cases:

- silence.
- impulse.
- full-scale sine.
- sine plus noise.

Synthetic fixtures should document generation parameters and should not be used
as perceptual ground truth for speech enhancement quality.

## Manual Listening Rubric

Manual review should check:

| Criterion | Pass condition |
| --- | --- |
| noise suppression | steady background noise is reduced without obvious artifacts |
| speech preservation | speech remains natural and intelligible |
| transient handling | plosives and sibilants are not smeared or clipped |
| silence behavior | silent input remains silent without musical noise |

Rate each criterion as:

- **Pass:** no audible artifact for the criterion.
- **Minor:** an artifact is present but not distracting in casual listening.
- **Fail:** an artifact is clearly audible to a non-expert listener.

Enhanced audio should not be represented as untouched original audio. This is
especially important for evidence-like recordings, interviews, journalism,
accessibility workflows, and archival material.
