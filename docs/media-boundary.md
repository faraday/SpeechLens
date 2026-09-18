# Media boundary

There is one media engine. FFmpeg/FFprobe owns probing, containers, routing,
packet copying, output recipes, encoding, and structural validation.
`AppleAACPCMDecoder` is one codec-specific plugin behind the existing
native-rate PCM source boundary; it is not a second media engine. `Processing`
owns MLX session scheduling, preview capture, source identity, the temporary
workspace, and atomic commit.

There is deliberately no backend registry, user-selectable decoder, fallback
chain, format-profile hierarchy, encoded replacement sidecar, or preservation
mode. AAC routing is fixed; package-internal injection exists only for tests.

For module ownership and the end-to-end flow, see [Architecture](architecture.md).
For the subprocess FFmpeg helper lifecycle, see [FFmpeg media engine](ffmpeg-backend.md).
