# Fixtures

SpeechLens tests use audio fixtures to verify structural behavior, audio
quality, sample-rate identity, and performance. Fixture documentation must cover
both technical metadata and redistribution status.

## Publication Rule

Being tracked in Git does not prove that a fixture is safe to redistribute.
Every public real-audio fixture needs documented source and permission.

For each real fixture, keep a record of:

- source or creator.
- license or written redistribution permission.
- source URL and dataset citation.
- exact upstream archive/path or row identifier, when available.
- sample rate, channels, duration, and bit depth.
- SHA-256 for `input.wav`, `expected.wav`, and any retained `ground_truth.wav`.

Real fixtures must come from documented public datasets with redistribution
permission. Private user recordings and material known to be sensitive,
confidential, or evidence-like must not be committed. If permission is unclear,
remove the fixture from the public repository or keep it out of Git. Required
quality coverage must still provide at least one redistributable complete
fixture at 16 kHz, 44.1 kHz, and 48 kHz.

## Current Real Fixtures

The current real fixtures are tracked in the repository. Publication status
depends on both dataset-level license and exact fixture provenance.
They are public research-dataset material and contain no private user
recordings or known sensitive, confidential, or evidence-like content.
Redistribution notices for the real fixture directory are kept in
`Tests/Fixtures/Real/NOTICE.md`.
Additional complete fixture pairs are discovered automatically, while the
three required sample-rate tiers prevent accidental loss of baseline coverage.

| Fixture | Rate | Duration | Channels | Input format | Expected format | Source | License/status |
| --- | ---: | ---: | ---: | --- | --- | --- | --- |
| `urgent_2024_fileid_26119` | 16000 Hz | 7.920000 s | 1 | Int16 WAV | Float32 WAV | URGENT 2024 validation `fileid_26119`; `expected.wav` is an inference-derived adaptation and `ground_truth.wav` is the clean Common Voice component | `input.wav` and `expected.wav`: CC BY-NC-SA 4.0; `ground_truth.wav`: CC0 1.0 |
| `chime_6_audio_1_trim_2m` | 16000 Hz | 120.000000 s | 1 | Int16 WAV | Float32 WAV | CHiME-6 corrected-synchronization recording, trimmed at two minutes; `expected.wav` is a 10 s / 0% overlap L4 inference-derived adaptation | CC BY-SA 4.0; attribution, modification, and ShareAlike terms required |
| `cityspeechmix_260-123286-0006__01_008131` | 44100 Hz | 10.000000 s | 1 | Int16 WAV | Float32 WAV | CitySpeechMix, Zenodo record `10.5281/zenodo.15405950`; `expected.wav` is an inference-derived adaptation | CC BY 4.0; attribution and modification notice required |
| `coraal_DCA_se2_ag1_f_07_1_trim_2m` | 44100 Hz | 120.000726 s | 1 | Int16 WAV | Float32 WAV | CORAAL DCA recording, trimmed at two minutes; `expected.wav` is a 10 s / 0% overlap L4 inference-derived adaptation | CC BY-NC-SA 4.0; attribution, NonCommercial, modification, and ShareAlike terms required |
| `edinburgh_56_speaker_p257_290` | 48000 Hz | 2.340917 s | 1 | Int16 WAV | Float32 WAV | Edinburgh DataShare noisy speech database, DOI `10.7488/ds/2117`; `expected.wav` is an inference-derived adaptation | CC BY 4.0; attribution and modification notice required |
| `edinburgh_56_speaker_merged_12e1f83c` | 48000 Hz | 120.720854 s | 1 | Int16 WAV | Int16 clean reference | Ordered noisy/clean concatenation from the Edinburgh DataShare test set, DOI `10.7488/ds/2117` | CC BY 4.0; attribution and concatenation notice required |

## Dataset Sources and Attribution

### Edinburgh 56 Speaker Fixture

The `edinburgh_56_speaker_p257_290` fixture is from the University of
Edinburgh DataShare “Noisy speech database for training speech enhancement
algorithms and TTS models” dataset:

```text
Valentini-Botinhao, Cassia. (2017).
Noisy speech database for training speech enhancement algorithms and TTS models, 2016 [sound].
University of Edinburgh. School of Informatics. Centre for Speech Technology Research (CSTR).
https://doi.org/10.7488/ds/2117
```

Source page:

```text
https://datashare.ed.ac.uk/items/6ed35425-bf14-4d2b-93a1-0a4984952757
```

The DataShare item links an end-user license text for Creative Commons
Attribution 4.0 International. Public redistribution must preserve attribution
and license notices.

`expected.wav` was produced from `input.wav` through RE-USE inference. It is
distributed under CC BY 4.0 as a modified version of the source recording.

### CitySpeechMix Fixture

The `cityspeechmix_260-123286-0006__01_008131` fixture is from CitySpeechMix:

```text
CitySpeechMix: A Simulated Dataset of Speech and Urban Sound Mixtures from LibriSpeech and SONYC-UST
Modan Tailleur, Mathieu Lagrange, Pierre Aumond, Vincent Tourre. 2025.
Zenodo. https://doi.org/10.5281/zenodo.15405950
```

Source page:

```text
https://zenodo.org/records/15405950
```

Zenodo lists the record under Creative Commons Attribution 4.0 International.
Public redistribution must preserve attribution and license notices.

`expected.wav` was produced from `input.wav` through RE-USE inference. It is
distributed under CC BY 4.0 as a modified version of the source recording.

### URGENT 2024 Fixture

The `urgent_2024_fileid_26119` fixture is from the URGENT 2024 official
validation dataset:

```text
https://huggingface.co/datasets/urgent-challenge/urgent2024_official
```

The Hugging Face dataset page marks the URGENT package as
`cc-by-nc-sa-4.0`. The URGENT data page lists the CommonVoice 11.0 English
source-speech component as CC0. SpeechLens still preserves source attribution
for CommonVoice as provenance, even where the component license does not require
attribution.

Citation:

```text
URGENT Challenge: Universality, Robustness, and Generalizability For Speech Enhancement
Wangyou Zhang, Robin Scheibler, Kohei Saijo, Samuele Cornell, Chenda Li,
Zhaoheng Ni, Jan Pirklbauer, Marvin Sach, Shinji Watanabe,
Tim Fingscheidt, Yanmin Qian. 2024.
Proc. Interspeech 2024, pages 4868-4872.
https://doi.org/10.21437/Interspeech.2024-1239
```

The fixture is documented from the URGENT validation metadata so the source
speech, noise, transform, and test parameters are reproducible.

```text
split:          validation
id:             fileid_26119
sampling_rate:  16000
snr_dB:         1.4567447900772095
duration:       7.920000 seconds
speech_uid:     cv11_5a43e5f94ac8ca256a1308f287130ed86e8e36b62e05ee97860551dc3b9ed39391bc9b816f63d4a73e798e19be9fe7516e74894967c4f6fcd3a220c2567fea74
speech_sid:     common_voice_en_19725931
noise_uid:      1MMHlvuv3YQ
rir_uid:        none
augmentation:   clipping(min=0.003939125654546594,max=0.9055080915651094)
transcript:     Brown continued working in the mental health area for the next
                few years.
```

`expected.wav` was generated by the pinned NVIDIA RE-USE chunk-inference path
on NVIDIA L4 with a 10-second chunk, `hop_length_portion=1.0` (zero overlap),
and no sample-rate conversion. The benchmark adapter writes mono 16 kHz
Float32 PCM WAV directly.
The former clean oracle is retained as `ground_truth.wav`; automated regression
comparison uses the NVIDIA reference in `expected.wav`.

`expected.wav` is distributed under CC BY-NC-SA 4.0 as an adaptation of
`input.wav`. The clean Common Voice component in `ground_truth.wav` is
distributed under CC0 1.0. NVIDIA NSCLv1 governed use of RE-USE during
generation; SpeechLens does not assert that the model license automatically
governs copyright in the generated audio.

Publication notes:

- preserve the URGENT package license notice and recommended citation.
- preserve attribution for Mozilla CommonVoice 11.0 English as the identified
  speech source, while noting that URGENT identifies this component as CC0.
- identify `expected.wav` as modified by RE-USE inference.
- document the clipping augmentation so quality-test expectations are clear.

### Real Fixture Hashes

| File | SHA-256 |
| --- | --- |
| `Tests/Fixtures/Real/16000/urgent_2024_fileid_26119/input.wav` | `dd844b5703ca47653d7d0d7f9c9e8417001cd21fc2a445811b909e057cf5e170` |
| `Tests/Fixtures/Real/16000/urgent_2024_fileid_26119/expected.wav` | `8c1cf7edefc06350197a5d084f968fe1717bd79976b666c59860060fea46328a` |
| `Tests/Fixtures/Real/16000/urgent_2024_fileid_26119/ground_truth.wav` | `de571ed4d391c39a0972f3725516d36341d81303be00126c3544f321ccafcc2d` |
| `Tests/Fixtures/Real/16000/chime_6_audio_1_trim_2m/input.wav` | `01be13bd7f08e88f9cfc418dc8e4a5d280115e785e8c571bfac5aece0040ce34` |
| `Tests/Fixtures/Real/16000/chime_6_audio_1_trim_2m/expected.wav` | `a51c5f96e533df323ccd14de1724411fe4868ebf19218f9477d667a56125f730` |
| `Tests/Fixtures/Real/44100/cityspeechmix_260-123286-0006__01_008131/input.wav` | `17d3ac9e11b6d8874afc20fc709b3756d3b9f0345ef8b29981385c63ca348838` |
| `Tests/Fixtures/Real/44100/cityspeechmix_260-123286-0006__01_008131/expected.wav` | `7d3140d546b15efddd15b4fd877d7a1e3984bb8b31b847cbd6bdb02e09905c98` |
| `Tests/Fixtures/Real/44100/coraal_DCA_se2_ag1_f_07_1_trim_2m/input.wav` | `f4c789736d349ca070060870852d5a0bced0e9ac9a0e72647ac2ee4f3342e739` |
| `Tests/Fixtures/Real/44100/coraal_DCA_se2_ag1_f_07_1_trim_2m/expected.wav` | `ae6f31cac89e7a4fe7ab0f4c7c7164e16936e7c98dbd27f7fbad655d115ae14e` |
| `Tests/Fixtures/Real/48000/edinburgh_56_speaker_p257_290/input.wav` | `2718b26e54c80d6bd77e6295dae34d70c3a04cd89a03d8a04c0ac80ddaa5eb8f` |
| `Tests/Fixtures/Real/48000/edinburgh_56_speaker_p257_290/expected.wav` | `9fd5a1733cc59071fa57242da74e85e1e801ca70d515601d2e3bfe13998a00ef` |
| `Tests/Fixtures/Real/48000/edinburgh_56_speaker_merged_12e1f83c/input.wav` | `0e3e9f49835d9e923fa6e524244108272cca5c6d7cb70e4091d03e960223cf4a` |
| `Tests/Fixtures/Real/48000/edinburgh_56_speaker_merged_12e1f83c/ground_truth.wav` | `26b629801a1d236a576cf83c3162c8ea7d9b938a2c99cb67faf0bfc5d903559c` |

## Synthetic Fixtures

Synthetic fixtures are intended for structural edge cases. They are generated
test signals, not perceptual ground truth for speech enhancement quality.

| File | Rate | Duration | Channels | Format | Description | SHA-256 |
| --- | ---: | ---: | ---: | --- | --- | --- |
| `Tests/Fixtures/Synthetic/silence_44100.wav` | 44100 Hz | 1.000000 s | 1 | Float32 WAV | all-zero signal | `135aad866515309887a9dc7bfbd2c621d34ce7af1e8534b28323d74cf4ba7eb8` |
| `Tests/Fixtures/Synthetic/impulse_44100.wav` | 44100 Hz | 1.000000 s | 1 | Float32 WAV | single impulse, otherwise silence | `b6aec5fa91d89c4dd3fb2247e32d5a4cb42e79f78b2fba15d86efe3be696512e` |
| `Tests/Fixtures/Synthetic/full_scale_sine_44100.wav` | 44100 Hz | 1.000000 s | 1 | Float32 WAV | full-scale 1 kHz sine | `408d7c62b34cdb5105e7f4f975a9b0746f7d2cc4cd3d14e54df6d2d1c3aaabb3` |
| `Tests/Fixtures/Synthetic/sine_plus_noise_44100.wav` | 44100 Hz | 3.000000 s | 1 | Float32 WAV | 1 kHz sine plus white noise at -20 dB SNR | `1f25cf72853a585cee022d62f33a294bff770bb68fe0263badbc4246dddb1616` |

### HE-AAC Decoder Fixture

`Tests/Fixtures/Codec/heaac-stereo-48000/heaac-stereo-48000.m4a` is a
project-authored, synthetic 3-second stereo signal. It is released under
CC0-1.0; it contains no speech, music, video, or third-party creative work.
Its source signal is silence, distinct left/right tones, a transient, and a
frequency sweep. The fixture is HE-AAC at a 48,000 Hz presentation rate and is
required by CI. Its generation recipe, encoder provenance, expected probe facts,
and SHA-256 are recorded beside the asset.

AVI, FLAC, and multi-stream MP4 regression inputs are generated in each test's
temporary directory and are intentionally not committed fixtures.

## Test Behavior

Fixture discovery is dynamic. Tests that require real fixtures should skip when
the fixture directory or complete `input.wav`/`expected.wav` pairs are absent.

This skip behavior lets maintainers run private or license-restricted fixture
sets locally without forcing those files into the public repository.
