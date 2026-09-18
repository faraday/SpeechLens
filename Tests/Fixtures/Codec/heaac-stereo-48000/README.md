# Synthetic HE-AAC fixture

This CI-owned fixture is project-authored synthetic data, released under
CC0-1.0. It contains 250 ms of silence, distinct 440/880 Hz stereo tones, a
single opposite-polarity stereo transient at 2 seconds, and a final stereo
frequency sweep. It contains no third-party creative work.

Generate it only with an external, non-shipping FFmpeg 8.1.2 build linked to
libfdk_aac 2.0.3:

```bash
swift Tools/generate-heaac-fixture.swift /path/to/fdk-ffmpeg \
  Tests/Fixtures/Codec/heaac-stereo-48000/heaac-stereo-48000.m4a
```

The generator uses `libfdk_aac`, `-profile:a aac_he`, 48,000 Hz stereo Float32
PCM input, and a 48 kb/s target bitrate. The bundled SpeechLens FFmpeg runtime
does not encode HE-AAC and must not be changed for fixture generation.

Verify with the bundled `ffprobe` and `shasum -a 256`; expected media facts and
the SHA-256 are in `fixture.json`.
