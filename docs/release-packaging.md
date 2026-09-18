# Release Packaging

The GUI release is archived and exported by `SpeechLens.xcodeproj`. SwiftPM
continues to build the CLI, libraries, WeightPort, and non-app tests. Both
artifacts package an MLX metallib and pinned FFmpeg/FFprobe helpers for unified
native-rate media handling across MP3, AVI, FLAC, MOV, and MP4 containers.
Model weights are not bundled by default.

When setup is required, the app automatically downloads the default artifact;
the GUI has no custom-weight selector. The CLI retains `--weights` and its
existing fallback resolution. The default artifact identity and SHA-256 are
compiled from `Sources/App/ModelArtifact.swift`.

## Build Environment

Build and package on an Apple Silicon Mac running macOS 15.6 or newer with
Xcode 26 and Swift 6.3 or newer selected. This developer-host requirement does
not change the release deployment target: the app and CLI must retain macOS 14
or newer compatibility.

## Local Package

Build unsigned local artifacts:

```bash
Tools/package-local.sh --configuration release
```

Expected outputs:

- `dist/local/SpeechLens.app`
- `dist/local/SpeechLens.app/Contents/Resources/AppIcon.icns`
- `dist/local/SpeechLens.app/Contents/Resources/Assets.car`
- `dist/local/SpeechLens.app/Contents/Resources/PrivacyInfo.xcprivacy`
- `dist/local/SpeechLens.app/Contents/Resources/en.lproj/Localizable.strings`
  (Xcode build product from `Sources/App/Localization/Localizable.xcstrings`)
- `dist/local/SpeechLens.app/Contents/Resources/LICENSE.txt`
- `dist/local/SpeechLens.app/Contents/Resources/THIRD-PARTY-LICENSES.txt`
- `dist/local/SpeechLens.app/Contents/Resources/SPEECHLENS-FFMPEG.txt`
- `dist/local/SpeechLens.app/Contents/MacOS/Resources/mlx.metallib`
- `dist/local/SpeechLens.app/Contents/MacOS/ffmpeg`
- `dist/local/SpeechLens.app/Contents/MacOS/ffprobe`
- `dist/local/speechlens-cli/speechlens-cli`
- `dist/local/speechlens-cli/ffmpeg`
- `dist/local/speechlens-cli/ffprobe`
- `dist/local/speechlens-cli/mlx.metallib`
- `dist/local/speechlens-cli/LICENSE.txt`
- `dist/local/speechlens-cli/THIRD-PARTY-LICENSES.txt`
- `dist/local/speechlens-cli/SPEECHLENS-FFMPEG.txt`

`Assets/AppIcon/SpeechLens.png` is the canonical app-icon artwork;
`Tools/generate-app-icon-assets.sh` generates the macOS size variants in
`AppIcon.appiconset`, and Xcode compiles that catalog into `Assets.car` and
`AppIcon.icns`. The primary app-icon build setting supplies the generated
Info.plist icon declarations. Xcode also owns the app executable, string
catalog, privacy manifest, and final app code signature. Its runtime-assets build phase
places FFmpeg/FFprobe in `Contents/MacOS`, `mlx.metallib` in
`Contents/MacOS/Resources`, and license notices in `Contents/Resources`.
`Tools/package-local.sh` copies the resulting Xcode product; it never assembles
an app bundle manually. The packaging workflow audits the app, CLI, and helpers with `otool` and
fails if any links a non-system dynamic library. `Tools/bootstrap-ffmpeg.sh`
builds two static arm64 executables from pinned, SHA-256-verified FFmpeg 8.1.2
and LAME 3.100 source. LAME is linked into `ffmpeg`; it is not shipped as a
third executable. Network support and unrelated formats are disabled. The
package audit requires the MP3/PNG/JPEG decoders; LAME, AudioToolbox AAC, and
MPEG-4 encoders; raw Float32 PCM and raw-video inputs; and FLAC and MOV/MP4
support. FFmpeg's native AAC encoder and all AAC decoders are excluded; the AAC
parser remains for packet copying. MPEG-4 video encoding remains fixture-only.
Both projects' LGPL texts are included in `THIRD-PARTY-LICENSES.txt`.

## Metallib

Runtime inference validates that a compatible `mlx.metallib` is already
packaged. It does not compile or repair the metallib at runtime.

Prepare a metallib manually:

```bash
Tools/build_mlx_metallib.sh --output /path/to/mlx.metallib
```

Source precedence:

1. `MLX_METALLIB_PATH`, if set, is verified and copied.
2. Otherwise the tool compiles MLX generated Metal sources from the SwiftPM
   checkout under `.build/checkouts/mlx-swift/`.

The generated metallib is compiled from Apple/MLX source distributed under MIT
terms. Packaging includes the applicable MLX and Swift dependency notices in
`THIRD-PARTY-LICENSES.txt`. Setting `MLX_METALLIB_PATH` affirms that the
override has equivalent MLX provenance; a differently sourced override must
provide correct licensing before it is used for a release.

This requires the selected Xcode 26 toolchain because it uses `xcrun metal` and
`xcrun metallib`.

## Signed Release

Official macOS releases require Developer ID signing and notarization. The
release script expects signing and notarization credentials in the environment
or a configured `notarytool` keychain profile.

```bash
DEVELOPER_ID_APPLICATION="Developer ID Application: Example (TEAMID)" \
APPLE_ID="person@example.com" \
APPLE_TEAM_ID="TEAMID" \
APPLE_APP_SPECIFIC_PASSWORD="xxxx-xxxx-xxxx-xxxx" \
Tools/release.sh --version 1.2.3
```

The release command:

1. builds local artifacts.
2. runs `xcodebuild archive` and Developer ID export; nested helpers are signed
   before Xcode signs the app.
3. signs the separately packaged CLI, then notarizes and staples the app.
4. creates, signs, notarizes, and staples the DMG.
5. notarizes the CLI zip.
6. verifies signatures and Gatekeeper assessment.
7. writes checksums.

Expected outputs under `dist/release/<version>/`:

- `SpeechLens-<version>.dmg`
- `speechlens-cli-<version>.zip`
- `checksums.txt`

## Release Validation

Before publishing a public release:

1. run model-backed tests with the exact pinned weights.
2. run the package smoke workflow.
3. build a signed release candidate.
4. download the DMG and CLI zip from the draft release.
5. verify `shasum -a 256 -c checksums.txt`.
6. launch the app from the DMG.
7. run `speechlens-cli --help` from the extracted CLI zip.
8. confirm release notes state that model weights are not bundled.
9. confirm both app and CLI packages contain `LICENSE.txt` and
   `THIRD-PARTY-LICENSES.txt`.
10. confirm packaged-helper media tests cover the required HE-AAC fixture,
    source-adaptive MP3, source-aware ABR-targeted AAC M4A/MOV,
    AAC-in-AVI rejection,
    ALAC/PCM/FLAC MOV/MP4, FLAC, and multi-stream MP4 transactions. Selected
    audio retains its codec family where the container supports it; nonselected
    MP4 streams remain packet-copied.
11. inspect the app and CLI Mach-O `LC_BUILD_VERSION` metadata and confirm
    `minos 14.0`.
12. verify `codesign --verify --strict` succeeds independently for
    `SpeechLens.app/Contents/MacOS/ffmpeg` and `ffprobe` before checking the app seal.
