# Media formats

SpeechLens preserves media integrity rather than forensic container identity.
Every selected audio stream is decoded and emitted at exactly its input sample
rate and channel order. SpeechLens never resamples.

| Input family | Normal enhanced output |
|---|---|
| WAV | Float32 PCM WAV |
| AIFF/AIFC | Float32 big-endian PCM AIFF |
| CAF | Float32 PCM CAF |
| FLAC | 24-bit FLAC, compression level 5 |
| MP3 | LAME MP3 at a source-adaptive bitrate |
| M4A | Apple-decoded AAC → source-aware AudioToolbox AAC in M4A |
| MP4 | Apple-decoded AAC for lossy audio; ALAC, FLAC, and PCM retain codec family/container |
| MOV | Apple-decoded AAC; ALAC and PCM retain codec family/container; FLAC becomes ALAC |
| AVI | MP3 → source-adaptive LAME MP3; AAC is rejected; other codecs → 24-bit PCM fallback |

When MP3 cannot represent the exact native rate/layout, planning tries M4A/AAC
and then Float32 CAF. When AAC cannot represent a native video track, planning
uses MOV/Float32 PCM. MOV cannot carry the bundled FFmpeg FLAC output, so a
selected FLAC stream in MOV is written as MOV/ALAC. The app chooses the planned
extension automatically; the CLI rejects a mismatched extension before loading
weights.

MP3 replacements use 160, 192, 256, or 320 kb/s according to the source bitrate
(192 kb/s when unknown), capped at 160 kb/s for sample rates through 24 kHz and
56 kb/s through 12 kHz. Re-encoding preserves codec family, sample rate, and
channel layout; it does not preserve encoded packets or the exact source bitrate.

AAC replacements use the reported AAC bitrate, or 256 kb/s when unavailable,
rounded to the next supported target between 32 and 320 kb/s. Preflight then
uses the highest target at or below that request which the bundled AudioToolbox
encoder can produce in the selected container. AudioToolbox AAC uses
average-bitrate mode, so the measured output bitrate may vary slightly.

AAC input is supported only in M4A, MP4, and MOV, where AVFoundation can select
the exact container track and report the decoded presentation rate. AAC inside
AVI receives a conversion-oriented error before model loading.

ALAC replacement uses bundled native 24-bit ALAC. For MOV/MP4 PCM inputs,
SpeechLens preserves the recognized PCM depth and endian representation; if the
destination cannot carry it, planning tries Float32 PCM in the same container
and then MOV/Float32 PCM for MP4. Selected audio is re-encoded, so it is never
packet-identical to the source.

For video, all non-selected audio, video, subtitle, and attached-picture streams
are packet-copied. Language, title, and default/forced dispositions are carried
where the destination supports them. A user-facing stream is never silently
dropped: preparation fails if the short mux rehearsal cannot carry it. Auxiliary
timecode, data, attachment, and opaque streams may be retained, regenerated, or
omitted and do not affect user-facing output validation.

Preflight decodes and muxes 50 milliseconds to verify that the selected stream,
encoder, container, and retained-stream recipe are compatible. This bounded
rehearsal does not claim that the complete source is readable; the full
transaction still validates decoding, encoding, and output structure.

Final validation compares the enhanced PCM timeline with the decoded output.
AAC and MP3 frame-count comparisons allow less than one complete codec frame of
padding or rounding. Encoded-duration comparisons allow up to three codec frames
for encoder priming and container timestamp quantization; video program-duration
metadata has a minimum tolerance of 0.25 seconds. These are acceptance bounds
covered by the codec characterization and output-validator tests, not claims of
packet identity.
