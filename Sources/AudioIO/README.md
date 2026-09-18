# AudioIO Module

## Responsibility

Exposes native-rate Float32 PCM primitives for uncompressed WAV, AIFF/AIFC, and
CAF files. Media capability probing, compressed formats, video containers,
timelines, metadata, and output policy belong to MediaIO. The production
boundary is sequential planar I/O so memory does not scale with file duration.

## Boundaries

ExtAudioFile converts supported source encodings and interleaving into
non-interleaved Float32 blocks at exactly the source sample rate. `nil` denotes
EOF; stream blocks are non-empty and have equal-length physical channels.

Whole-file reading, writing, interleaving, and downmix conveniences are test-only
and live in `Tests/TestSupport`. They are intentionally absent from the AudioIO
product so production callers cannot bypass the bounded streaming path.

## Prohibitions

- No sample-rate conversion or default sample rate.
- No whole-file production buffer API.
- No MLX, model behavior, routing policy, signal analysis, AppKit, or SwiftUI.

See [Architecture](../../docs/architecture.md) and
[Media boundary](../../docs/media-boundary.md) for the canonical ownership
model.
