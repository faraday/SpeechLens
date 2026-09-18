# Kernel Optimization Rationale

SpeechLens uses specialized Metal kernels when the equivalent general-purpose
MLX graph would impose unacceptable runtime cost or unified-memory pressure.
This document records the evidence and constraints behind the specialized
causal depthwise convolution and selective-scan kernels used by each Mamba
block.

## Why Conv1d Was Specialized

A profiling run on April 18, 2026 measured the pre-optimization Mamba path on a
five-second, 44.1 kHz synthetic fixture. Temporary `MLX.eval()` barriers were
placed around the major Mamba operations so elapsed time represented GPU work
rather than lazy Swift dispatch. The 220,500-sample input exercised 120 Mamba
calls.

| Component | Cumulative time | Share of measured Mamba time |
| --- | ---: | ---: |
| MLXNN grouped `Conv1d` | 2,848.06 ms | 54.5% |
| Metal selective scan | 1,058.68 ms | 20.3% |
| input projection | 775.44 ms | 14.8% |
| SiLU | 146.39 ms | 2.8% |
| state projection | 137.35 ms | 2.6% |
| output projection | 129.63 ms | 2.5% |
| delta projection | 127.45 ms | 2.4% |

These figures are a historical bottleneck measurement, not a current benchmark
or a cross-machine performance claim. The original profiling note did not
record the hardware, toolchain, or build configuration, so the figures should
be read only as a within-run component ranking. They showed that the grouped
convolution was the dominant optimization target and cost more than twice the
already-fused selective scan. See [Performance](performance.md) for the current
release gates and reporting requirements.

The specialized Metal kernels reduced the end-to-end 5-second 44.1 kHz
inference from the profiled ~5.22 s baseline to **2.219 s** (14.06× faster
than the original PyTorch/MPS path at 31.19 s). See
[Performance](performance.md#execution-path-progression) for the full
measured progression.

## Rejected MLX Graph Rewrite

An explicit shift, multiply, and sum formulation was numerically accurate and
reduced the five-second runtime from about 5.34 seconds to 3.56 seconds. It was
not safe for production chunks. Each Mamba call expanded one convolution into
roughly eight lazy graph nodes with full `[batch, sequence, channel]`
intermediates. Because inference evaluates the graph at chunk boundaries, those
intermediates accumulated across 120 calls.

In the implementation measured at the time, the convolution intermediates for a
30-second chunk were estimated at about 5 GB. Combined with the projections and
scan state, the retained graph exhausted practical unified-memory budgets.
Adding evaluation barriers after every block would bound memory, but would also
remove useful cross-block scheduling and make performance more
synchronization-sensitive.

The rejected approach established an important rule: an optimization must
control lazy-graph size at production sequence lengths, not merely improve a
short-fixture wall time.

## Current Metal Kernel

`MetalCausalConv1d` performs the depthwise causal convolution in one dispatch and
produces one output tensor. One thread owns a `(batch, channel)` pair, keeps the
three previous samples in registers, and walks the sequence dimension. Adjacent
channel threads access adjacent elements in the row-major `[B, L, D]` layout.

The call site and kernel share the following model-specific contract. The Swift
wrapper validates the tensor ranks and shapes before dispatch:

| Property | Required value |
| --- | --- |
| input | `[B, L, D]`, Float32 |
| weights | `[D, 4, 1]` |
| bias | `[D]` |
| kernel size | 4 |
| grouping | depthwise: input channels = output channels = groups |
| padding | three zero samples on the causal left edge |
| output | `[B, L, D]` |

If validation or dispatch fails, `Mamba` logs the failure and uses
`MLXNN.Conv1d`, trimming its padded output back to `L`. Setting
`SPEECHLENS_DISABLE_METAL_CONV1D=1` selects that fallback explicitly. This
fallback is useful for diagnosis and parity checks; it is not the optimized
runtime path.

The implementation is in
[`Sources/Inference/MetalCausalConv1d.swift`](../Sources/Inference/MetalCausalConv1d.swift),
and the call site and fallback behavior are in
[`Sources/Inference/Mamba.swift`](../Sources/Inference/Mamba.swift).

## Fixed Selective Scan

`MetalSelectiveScan` fuses the Mamba recurrence, softplus, and `-exp(A_log)`
into one Metal dispatch over `[B, L, D]` inputs. Each thread owns one `(batch,
channel)` pair and walks the sequence while retaining the state in registers.

In the shapes below, `B` is batch size, `L` is sequence length, and `D` is the
Mamba inner-channel width. The fixed `16` is the number of SSM state values
retained per inner channel. `delta_raw` is the pre-softplus time-step
parameter; `u` is the input activation; and `z` is the output gate. `B` and
`C` are the sequence-varying state input and output coefficients, while
`A_log` and `D` are learned per-channel parameters.

The kernel is intentionally specialized for the supported RE-USE model layout:

| Tensor | Role | Required shape |
| --- | --- | --- |
| `A_log` | learned state decay, per inner channel | `[D, 16]`, Float32 |
| `B`, `C` | state input and output coefficients, per sequence step | `[B, L, 16]`, Float32 |
| `delta_raw` | pre-softplus time-step parameter | `[B, L, D]`, Float32 |
| `u`, `z` | input activation and output gate | `[B, L, D]`, Float32 |
| `D` | learned skip parameter, per inner channel | `[D]`, Float32 |

`MambaEnhancer` validates these model shape requirements while loading the
checkpoint, before it constructs or caches a processing pipeline. Fixed-16
Metal selective scan is mandatory: an incompatible model becomes a typed
model-load compatibility failure and the existing UI recovery state explains
how to update or re-download the app and model. The kernel rechecks input
shapes defensively; a failure after successful loading is an internal
invariant violation. There is no MLX selective-scan fallback or diagnostic
runtime switch.

### Fusion decisions

The kernel accepts raw `A_log` and fuses `-exp(A_log)` into per-thread
register init. That avoids one full-tensor MLX op per Mamba call. The values
are hoisted out of the `L` loop: without the hoist the kernel would reissue
`L×N` global loads per thread, and the Metal compiler cannot hoist on its own
because it must assume `out` might alias `A_log` through the buffer interface.

Softplus on `delta_raw` is likewise fused in-kernel using the same
`log(1 + exp(x))` as MLX's eager graph. That deletes the three-dispatch
softplus graph (`exp`, `+1`, `log`) that would otherwise run per Mamba call
and lets the scan consume the raw `dtProj` output.

The implementation is in
[`Sources/Inference/MetalSelectiveScan.swift`](../Sources/Inference/MetalSelectiveScan.swift).

Strict Mode exposes the phase-parity `fast-bitcast-scalar` candidate as an
opt-in production execution mode. It keeps the fixed-16 recurrence and
dispatch geometry while using stable softplus, direct-division SiLU, explicit
Float32 product ordering, ordinary `exp` for `A_log`, and bounded bitcast
exponent scaling for the per-step decay. Standard mode remains the default.

The fast-bitcast-scalar decay exponential uses range reduction and a 6th-degree
Horner polynomial to approximate `exp(x)` for the recurrence decay term:

1. Range-reduce: `y = x × log₂(e)`, `k = rint(y)`, `f = y − k`.
2. Polynomial: `p(f) = 1 + 0.6931472f + 0.24022651f² + 0.055503407f³ + 0.0096180400f⁴ + 0.0013395279f⁵ + 0.00015465313f⁶`.
3. Reconstruct: scale `p(f)` by `2^k` via IEEE exponent-field bitcast when `k ≥ −126`; return 0 when `k < −126`.

Offline emulation accuracy on 4,128,768 retained block-zero arguments:
max relative error 2.75 × 10⁻⁷ vs float64 `exp`. On a 100,001-point grid over
[−86, 0]: max relative error 3.79 × 10⁻⁶. The subnormal cutoff returns 0 at
`x = −88` where `exp(−88) ≈ 6.05 × 10⁻³⁹`.

## Negative Optimization Results

Several kernel fusion and compilation strategies were benchmarked and rejected
after showing rate-dependent or negative returns. All measurements used
5 warmups, 20 timed trials on three fixtures spanning 16 kHz, 44.1 kHz, and
48 kHz.

| Strategy | 16 kHz (7.92 s) | 44.1 kHz (10.00 s) | 48 kHz (2.34 s) | Disposition |
| --- | ---: | ---: | ---: | --- |
| Conv–SiLU fusion | −3.1% | +7.5% | +13.2% | Rejected |
| Compiled projections (`mx.compile`) | +4.1% | +4.6% | +15.6% | Rejected |
| dtProj–scan fusion | −4.7% | +2.9% | +13.1% | Rejected |

**Conv–SiLU fusion** merged the causal Conv1d activation into the kernel.
It helped the shortest spectral tensor (16 kHz) but degraded the
larger 44.1/48 kHz tensors, likely due to increased register pressure
limiting occupancy. Active memory was unchanged; fidelity was retained
(SNR 124.6–128.9 dB, LSD < 0.001 dB).

**Compiled projections** used MLX's shape-polymorphic compilation cache.
Despite a 99.97% hit rate (59,984 of 60,000 calls), compiled closures
substituted `matmul + bias` for the optimized `Linear/addMM` path, making
every fixture slower. Physical footprint rose ~6% on the 44.1 kHz fixture.

**dtProj–scan fusion** folded the rank-4 delta projection into the scan
kernel, avoiding the `[B, L, D]` intermediate. It reduced active memory by
up to 11.7% on the 44.1 kHz fixture but ran slower at both high rates.

Additional rejected directions include parallel blockwise scan (26–28×
slower), SIMD16 state-vector scan (3.4–4.0× slower, numerically exact),
bidirectional merge fusion (+9% to +35%), software-pipelined scan loops
(+14% to +37%), and forward/backward branch packing (+11% to +18%).

These results illustrate that kernel optimizations for state-space models
are strongly workload-dependent.

## Validation Expectations

Changes to this kernel or its call site should demonstrate all of the following:

1. numerical parity with the MLX grouped-convolution fallback;
2. identical causal-padding and output-length behavior;
3. stable memory use at both 5-second and 30-second chunk sizes;
4. no regression in the real-fixture throughput and peak-RSS gates; and
5. no regression in the audio-quality gates.

Benchmark reports must include hardware, OS and toolchain versions, fixture,
sample rate, chunk settings, and build configuration.
