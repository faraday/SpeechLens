# App Module

## Responsibility

Presents the macOS menu-bar workflow for selecting media and enhancing and
previewing its audio while delegating bounded processing, model execution, and
media-container handling to their owning modules.

## Boundaries

- `AppState` owns workflow state and actions; injected adapters own media-job
  preparation, file panels, Finder reveal, and model/pipeline caching.
- `ModelStore` owns pinned-model download and cache state.
- Playback owns players, seeking, bounded waveform presentation, and observer
  lifetime.
- Presentation maps typed workflow and diagnostic facts to localized resources;
  it does not add media policy or expose raw technical errors.
- App-only reporting remains consent-gated and separate from the local,
  network-free Diagnostics module.

## Prohibitions

- No Accelerate numerical kernels.
- No direct Metal or MetalKit imports or dispatch.
- No direct audio decoding or encoding; inspection and bounded analysis go
  through MediaIO (with AudioIO retained only as an uncompressed primitive).
- No whole-file audio buffers.
- No sample-rate conversion.
- No model tensor, STFT, channel-scheduling, or atomic-file-transaction logic.
- No model/pipeline cache or menu-window lifecycle state inside `AppState`.
- No custom-model picker, custom-model preference, or app-specific weight
  resolution path.

See [Architecture](../../docs/architecture.md),
[Media boundary](../../docs/media-boundary.md), and
[Model artifacts](../../docs/model-artifacts.md) for the canonical workflow and
ownership contracts.
