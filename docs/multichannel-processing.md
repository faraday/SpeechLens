# Serial Multichannel Processing

SpeechLens preserves native sample rate, physical channel order, channel count,
and exact frame count. There is no duration-sized decoded or enhanced buffer.

MediaIO uses the focused Apple AAC decoder or the pinned FFmpeg decoder to
supply bounded, timed planar blocks.
Processing creates one mono Inference
session per physical channel, all backed by the same loaded `MambaEnhancer`.
For each block it advances channel 0, channel 1, and so on, strictly serially.
Only after every channel succeeds is the aligned block appended to a private
temporary output.

Inference owns model-window geometry, overlap-add, and final-tail behavior.
Processing owns file lifetime, progress, cancellation, channel order, and the
output transaction. MediaIO owns FFprobe inspection, timestamp reconciliation,
native-rate planar PCM adaptation, the chosen audio recipe, and packet copying
of retained streams; AudioIO owns planar block primitives and preview WAV I/O.

After EOF, Processing closes and validates the temporary output, then atomically
moves or replaces the destination. Failure or cancellation deletes the private
partial file and leaves an existing destination unchanged.

Waveform display may downmix during a bounded presentation scan. Enhancement
never downmixes, resamples, batches channels together, or analyzes channel
correlation. Runtime model calls remain B=1.
