# MediaIO

MediaIO is SpeechLens's single FFmpeg media boundary.

- FFprobe inspects every supported format.
- AAC in M4A/MP4/MOV is decoded to continuous, native-rate Float32 PCM by the
  focused Apple AAC decoder. Other selected audio uses FFmpeg.
- One ordered policy matrix selects output-container and encoder candidates;
  the planner freezes stream routing into each execution plan.
- A short mux rehearsal rejects incompatible jobs before inference.
- One bounded FFmpeg sink writes the final transaction file directly while
  packet-copying all other user-facing streams.
- `MediaOutputNotice` carries typed informational and warning outcomes for
  fallback containers and omitted auxiliary streams; consumers own wording.
- Output validation checks the container, native audio shape, retained stream
  order and identity metadata, replacement duration, and video program duration.

MediaIO must never resample, link FFmpeg libraries, introduce a generalized
backend router, or add format-specific preservation profiles.

See [Media boundary](../../docs/media-boundary.md),
[FFmpeg media engine](../../docs/ffmpeg-backend.md), and
[Media formats](../../docs/media-formats.md) for the canonical contracts.
