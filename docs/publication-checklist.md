# Publication Checklist

This checklist is for maintainers preparing SpeechLens for public release. It is
not required reading for users who only want to build, run, or contribute small
changes.

## Repository

- The source-code license gate is the top-level [Apache License 2.0](../LICENSE).
  Leave the LICENSE appendix placeholders (`[yyyy]` / `[name of copyright owner]`)
  as Apache’s stock template; they are not project metadata.
- Project copyright ownership is stated in `README.md` and root `NOTICE`.
- `README.md` summarizes SpeechLens, links the public documentation, and states
  the source-code and external-artifact license boundaries.
- `CONTRIBUTING.md` and `SECURITY.md` exist at the repository root or are linked
  clearly from the root README.
- Generated local artifacts such as `.build/`, `.venv/`, `dist/`, and
  `TestResults/` are not tracked.
- Every committed binary asset is classified in `ASSET-LICENSES.md`.

## Model Artifacts

- Model weights are documented as separately licensed artifacts.
- Public docs state that the current RE-USE-derived weights are under NVIDIA
  One-Way Noncommercial License terms.
- Release artifacts do not bundle model weights unless their license permits
  that distribution path.
- Downloaded model artifacts are pinned by immutable revision and SHA-256.
- `Sources/App/ModelArtifact.swift` is the reviewed trust anchor for the
  default artifact; the downloaded manifest is never trusted by itself.
- Cached default weights fail closed when the manifest is missing, malformed,
  or inconsistent with either the pinned checksum or actual model bytes.

## Fixtures

- Any bundled real audio fixtures have documented redistribution permission.
- Fixture docs include source, license or written permission, sample rate,
  duration, and SHA-256.
- Private or unclear-rights fixtures are excluded from the public repository.
- `docs/fixtures.md` is updated whenever fixture files change.

## CI and GitHub Settings

- CI runs on macOS 26 and selects Xcode 26 with Swift 6.3 or newer.
- Public CI works for non-model tests without private credentials.
- The non-model CI slice includes Xcode `SpeechLensAppTests` for model-cache verification and
  playback/waveform state.
- Model-backed CI behavior is intentional: public, private, or documented as
  maintainer-only.
- Repository secrets are configured only for workflows that need them.
- Release workflows use protected environments for signing and notarization.

## Release Artifacts

- App and CLI Mach-O metadata report a macOS 14.0 minimum deployment target.
- App and CLI artifacts are signed and notarized.
- App and CLI artifacts contain the SpeechLens `LICENSE.txt` and generated
  `THIRD-PARTY-LICENSES.txt`.
- `checksums.txt` is generated and verified before publishing.
- Release notes state whether model weights are bundled or downloaded later.
- Draft releases are tested by downloading the public artifacts, not only by
  inspecting local build output.

This checklist does not replace a repository license, fixture license, or model
license.
