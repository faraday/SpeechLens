# Processing

Processing owns one bounded media transaction and serial physical-channel MLX
scheduling.

`MediaJobPreparer` freezes source identity, selected stream, native audio
properties, output recipe, and successful FFmpeg preflight. The enhancement pass
tees original and enhanced PCM to independent Float32 WAV previews when
requested. The FFmpeg output sink writes the transaction's temporary destination
directly; Processing validates, rechecks source identity, and atomically commits.
`MediaProcessingResult` carries MediaIO's typed output notices without converting
them to presentation strings.

Processing must not contain container profiles, remux sidecars, metadata
preservation rules, sample-rate conversion, or runtime inference other than the
injected MLX enhancer.

See [Architecture](../../docs/architecture.md),
[Media boundary](../../docs/media-boundary.md), and
[Multichannel processing](../../docs/multichannel-processing.md) for the
canonical transaction and scheduling contracts.
