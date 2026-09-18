# Unified FFmpeg media engine

SpeechLens uses one separately bundled FFmpeg/FFprobe runtime for production
inspection, non-AAC decoding, audio encoding, packet copying, and muxing. It
does not link FFmpeg libraries. A focused AVFoundation component decodes AAC
from M4A, MP4, and MOV directly to native-rate PCM.

The runtime is built from the checksum-pinned, unmodified FFmpeg 8.1.2 release.
It includes pristine LAME and upstream AudioToolbox `aac_at` encoding. FFmpeg's
native AAC encoder and every FFmpeg AAC decoder are disabled; the AAC parser is
retained for inspection and packet copying. There are no SpeechLens source
patches.

## Transaction

1. FFprobe returns the ordered stream inventory, container track IDs, and
   encoded properties. A bounded Apple probe supplies AAC presentation shape.
2. Preparation chooses a native-rate output recipe and rehearses it with a
   short silent replacement before model loading.
3. AVFoundation renders selected AAC as bounded Float32 PCM; FFmpeg renders
   other selected formats. Timestamp gaps become zero-valued samples, priming
   and padding are trimmed to the presentation timeline, and no path resamples.
4. Processing enhances each physical channel serially through MLX.
5. One FFmpeg process accepts enhanced PCM through a bounded pipe, substitutes
   it at the selected stream position, packet-copies every other user-facing
   stream, and writes the transaction output directly.
6. FFprobe performs structural validation before atomic commit.

Audio, video, subtitle, and attached-picture streams are media essence. Generic
data and timecode streams are omitted and reported. Compatible metadata and
chapters are copied best-effort; atom layout, track IDs, private associations,
and metadata byte identity are not product invariants.

Cancellation closes pipes, terminates child processes, removes transaction-owned
temporary files, and never damages an existing destination.
