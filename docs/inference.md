# Inference Runtime

Inference runs the SE-Mamba mono forward pass with MLX on Metal. It owns model
validation, native-rate STFT/iSTFT scaling, bounded streaming sessions,
look-ahead, overlap-add, and final-tail semantics. File I/O, channel layout, and
physical-channel scheduling remain outside the module.

## Streaming Contract

`MambaEnhancer` loads one model and serializes every model-window invocation.
Independent mono sessions retain only bounded input, overlap-add, and tail
state. Each session has an explicit native sample rate, and `finish()` makes
the total emitted frame count equal the total appended frame count.

Overlapping windows use complementary squared-sine and squared-cosine weights.
Their pointwise sum is one, so overlap-add preserves constant gain; normalization
is skipped only when its accumulated weight is at most `1e-8`, avoiding division
by a numerically empty window.

Processing creates one session per physical channel and advances those sessions
serially. Runtime model calls remain B=1; internal operators retain B=2 parity
coverage so equal-shaped windows can be batched in the future if measurement
justifies it.

## Supported Model Layout

The runtime supports the fixed 30-block RE-USE architecture with Mamba
`d_state == 16`. Model weights are validated against this layout before
parameter mapping. A model artifact may have a different identity or checksum,
but arbitrary Mamba architectures are not supported.

Fixed-16 Metal selective scan is mandatory. See
[Kernel Optimization](kernel-optimization.md) for its tensor contract,
fallback policy, and validation expectations.

`MambaEnhancer` supports two numerical modes. Standard mode is the default and
keeps the existing fixed-16 kernel. Strict Mode is opt-in through the App
switch or CLI `--strict` flag. It selects the fast-bitcast-scalar kernel, which
uses stable softplus (`max(x, 0) + log1p(exp(-abs(x)))`), direct-division SiLU,
ordinary `exp` for learned `A_log` decay initialization, disabled fused
contraction, the existing Float32 recurrence ordering, and a degree-six
base-2 polynomial whose exponent is applied with an IEEE-754 bitcast. Values
below the supported exponent range underflow to zero. The mode does not alter
model layout, streaming, sample-rate identity, or output frame-count identity.

## STFT and iSTFT Parity

STFT parameters mirror the pinned NVIDIA RE-USE path. Each base parameter is
multiplied by the native sample rate, integer-divided by 8 kHz, then rounded up
to an even value; at 44.1 kHz this produces a 220-sample hop. Analysis and
manual iSTFT synthesis use PyTorch's periodic Hann window (`periodic == true`).

After reflect center padding, STFT framing retains only complete windows,
matching PyTorch's floor-based `torch.stft` enumeration. An incomplete final
hop is discarded rather than zero-padded. iSTFT reconstruction remains trimmed
to the original signal length, so the public streaming contract still emits
exactly as many frames as were appended.

After non-negative `expm1` magnitude reconstruction, a time frame is zeroed
when a strict majority of its frequency bins are zero, matching NVIDIA's sweep
artifact suppression rule.

Every manual `asStrided` view is checked with overflow-safe arithmetic before
it reaches MLX. For shape `s`, strides `t`, and offset `o`, the referenced range
is:

```text
o + sum(min(0, (s[i] - 1) * t[i]))
...
o + sum(max(0, (s[i] - 1) * t[i]))
```

An empty dimension references no elements.

## Runtime Constraints

- MLX graph construction and evaluation run explicitly on the Metal GPU.
- No resampling or assumed sample rate is permitted.
- No file, container, or channel-layout interpretation belongs in Inference.
- No PyTorch, CoreML, ANE, or runtime model conversion is permitted.
- `InferenceSettings` is the source of truth for chunk duration and overlap.
