# Asset Licenses

Except where noted below, SpeechLens-authored source code, documentation, and
assets are licensed under the Apache License 2.0 in [`LICENSE`](LICENSE).

| Files or generated artifact | Copyright or source | License | Notes |
| --- | --- | --- | --- |
| `Assets/AppIcon/SpeechLens.png`, `Sources/App/Assets.xcassets/AppIcon.appiconset/` | Copyright 2026 Çağatay Çallı | Apache-2.0 | Project-authored app artwork. |
| `Assets/MenuBarIcon/MenuBarIcon.svg`, `Sources/App/Assets.xcassets/MenuBarIcon.imageset/MenuBarIcon.pdf` | Copyright 2026 Çağatay Çallı | Apache-2.0 | Project-authored menu-bar template mark (gapped lens + through-signal). |
| `docs/assets/cache-tradeoff.png` | Copyright 2026 Çağatay Çallı | Apache-2.0 | Project-authored benchmark visualization plot (buffer cache policy sweep). |
| `Tests/Fixtures/Synthetic/*.wav` | Copyright 2026 Çağatay Çallı | Apache-2.0 | Project-authored generated test signals. |
| `Tests/Fixtures/Codec/heaac-stereo-48000/` | SpeechLens contributors | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | Project-authored synthetic HE-AAC fixture, manifest, and license; generated once with the documented external `libfdk_aac` toolchain and committed for deterministic CI. |
| `Tests/Fixtures/Real/16000/urgent_2024_fileid_26119/input.wav`, `expected.wav` | URGENT 2024 contributors | [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) | `expected.wav` is an adaptation of `input.wav` produced through RE-USE inference. |
| `Tests/Fixtures/Real/16000/urgent_2024_fileid_26119/ground_truth.wav` | Mozilla Common Voice contributor identified by the URGENT metadata | [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/) | Clean Common Voice source-speech component retained as an oracle. |
| `Tests/Fixtures/Real/16000/chime_6_audio_1_trim_2m/*.wav` | CHiME-6 contributors | [CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/) | `expected.wav` is an adaptation of `input.wav` produced through RE-USE inference. |
| `Tests/Fixtures/Real/44100/cityspeechmix_260-123286-0006__01_008131/*.wav` | CitySpeechMix contributors | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | `expected.wav` is an adaptation of `input.wav` produced through RE-USE inference. |
| `Tests/Fixtures/Real/44100/coraal_DCA_se2_ag1_f_07_1_trim_2m/*.wav` | CORAAL contributors | [CC BY-NC-SA 4.0](https://creativecommons.org/licenses/by-nc-sa/4.0/) | `expected.wav` is an adaptation of `input.wav` produced through RE-USE inference. |
| `Tests/Fixtures/Real/48000/edinburgh_56_speaker_*/*.wav` | Cassia Valentini-Botinhao and the University of Edinburgh | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | `expected.wav` is an adaptation of `input.wav` produced through RE-USE inference; clean ground truth is sourced from the Edinburgh DataShare release. |
| `docs/assets/demo/cityspeechmix-*.mp3` | CitySpeechMix contributors | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Browser-friendly adaptations of the 44.1 kHz source and SpeechLens-enhanced output; full attribution, modification notice, generation identity, and hashes are in the adjacent demo manifest. |
| `docs/assets/demo/edinburgh-*.mp3` | Cassia Valentini-Botinhao and the University of Edinburgh | [CC BY 4.0](https://creativecommons.org/licenses/by/4.0/) | Browser-friendly adaptations of the 48 kHz source and SpeechLens-enhanced output; full attribution, modification notice, generation identity, and hashes are in the adjacent demo manifest. |
| `Tests/Fixtures/Reference/parity_probes.json` | Copyright 2026 Çağatay Çallı | Apache-2.0 | SpeechLens-authored provenance manifest. |
| `Tools/reference_runner.py`, `Tests/Fixtures/Reference/parity_probes.safetensors` | NVIDIA RE-USE and SpeechLens contributors | `LicenseRef-NVIDIA-One-Way-Noncommercial-NSCLv1` | Conservative classification for the adapted reference implementation and its generated numerical probes. See [`LICENSE-NVIDIA-NSCLv1.txt`](LICENSE-NVIDIA-NSCLv1.txt). |
| Packaged `mlx.metallib` | Apple Inc. and MLX contributors | MIT | Compiled from the pinned MLX generated Metal sources. Release packages carry the applicable notice in `THIRD-PARTY-LICENSES.txt`. |

Detailed real-fixture provenance, attribution, transformations, and hashes are
maintained in [`Tests/Fixtures/Real/NOTICE.md`](Tests/Fixtures/Real/NOTICE.md)
and [`docs/fixtures.md`](docs/fixtures.md).
