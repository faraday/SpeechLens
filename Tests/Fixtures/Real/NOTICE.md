# Real Audio Fixture Notices

This directory contains real audio fixtures used for SpeechLens regression
tests. Preserve the source, attribution, license, and modification notices below
when redistributing these files. Technical metadata and SHA-256 hashes are in
[`docs/fixtures.md`](../../../docs/fixtures.md).

Each `expected.wav` is an adaptation of its paired `input.wav`, produced through
speech-enhancement inference using NVIDIA RE-USE. SpeechLens intentionally
distributes each adaptation under the input recording's license. The NVIDIA
One-Way Noncommercial License governed use of the model during generation; this
notice does not assert that the model license automatically governs copyright in
the generated audio.

## URGENT 2024 `fileid_26119`

Files and status:

- `16000/urgent_2024_fileid_26119/input.wav` is the noisy URGENT validation
  recording, including the documented clipping augmentation.
- `16000/urgent_2024_fileid_26119/expected.wav` is a modified version produced
  from `input.wav` by NVIDIA RE-USE inference on NVIDIA L4 as mono 16 kHz
  Float32 PCM WAV.
- `16000/urgent_2024_fileid_26119/ground_truth.wav` is the clean Common Voice
  source-speech component identified by the URGENT metadata.

Source:

<https://huggingface.co/datasets/urgent-challenge/urgent2024_official>

`input.wav` and `expected.wav` are distributed under Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 International:

<https://creativecommons.org/licenses/by-nc-sa/4.0/>

The URGENT metadata identifies the clean source-speech component retained as
`ground_truth.wav` as Mozilla Common Voice 11.0 English under CC0 1.0:

<https://creativecommons.org/publicdomain/zero/1.0/>

Citation:

```text
URGENT Challenge: Universality, Robustness, and Generalizability For Speech Enhancement
Wangyou Zhang, Robin Scheibler, Kohei Saijo, Samuele Cornell, Chenda Li,
Zhaoheng Ni, Jan Pirklbauer, Marvin Sach, Shinji Watanabe,
Tim Fingscheidt, Yanmin Qian. 2024.
Proc. Interspeech 2024, pages 4868-4872.
https://doi.org/10.21437/Interspeech.2024-1239
```

## CHiME-6 `audio_1_trim_2m`

Files and status:

- `16000/chime_6_audio_1_trim_2m/input.wav` is a CHiME-6 recording sourced
  from the `argmaxinc/chime-6` Hugging Face dataset and trimmed at the
  two-minute mark.
- `16000/chime_6_audio_1_trim_2m/expected.wav` is a modified version produced
  from `input.wav` by NVIDIA RE-USE inference on NVIDIA L4 as mono 16 kHz
  Float32 PCM WAV. The reference uses a 10-second chunk, zero overlap, and no
  sample-rate conversion.

Source and attribution:

CHiME-6 is the corrected-synchronization version of CHiME-5. This fixture was
sourced from:

<https://huggingface.co/datasets/argmaxinc/chime-6>

The original dataset's attribution and license are published by OpenSLR:

<https://openslr.org/150/>

```text
Jon Barker, Shinji Watanabe, Emmanuel Vincent, and Jan Trmal. 2018.
The Fifth 'CHiME' Speech Separation and Recognition Challenge: Dataset, Task
and Baselines. Proc. Interspeech 2018, pages 1561-1565.
https://doi.org/10.21437/Interspeech.2018-1768
```

This fixture is distributed under Creative Commons Attribution-ShareAlike 4.0
International. Preserve the attribution, license URL, trimming modification
notice, and ShareAlike terms:

<https://creativecommons.org/licenses/by-sa/4.0/>

## CitySpeechMix

Files and status:

- `44100/cityspeechmix_260-123286-0006__01_008131/input.wav` is the source
  CitySpeechMix recording.
- `44100/cityspeechmix_260-123286-0006__01_008131/expected.wav` is a modified
  version produced from `input.wav` by RE-USE inference.

Source and attribution:

```text
CitySpeechMix: A Simulated Dataset of Speech and Urban Sound Mixtures from LibriSpeech and SONYC-UST
Modan Tailleur, Mathieu Lagrange, Pierre Aumond, Vincent Tourre. 2025.
Zenodo. https://doi.org/10.5281/zenodo.15405950
```

Both files are distributed under Creative Commons Attribution 4.0
International. Preserve the attribution, license URL, and modification notice:

<https://creativecommons.org/licenses/by/4.0/>

## CORAAL `DCA_se2_ag1_f_07_1_trim_2m`

Files and status:

- `44100/coraal_DCA_se2_ag1_f_07_1_trim_2m/input.wav` is a CORAAL recording
  sourced from the `zsayers/CORAAL` Hugging Face dataset and trimmed at the
  two-minute mark.
- `44100/coraal_DCA_se2_ag1_f_07_1_trim_2m/expected.wav` is a modified version
  produced from `input.wav` by NVIDIA RE-USE inference on NVIDIA L4 as mono
  44.1 kHz Float32 PCM WAV. The reference uses a 10-second chunk, zero overlap,
  and no sample-rate conversion.

Source and attribution:

The Corpus of Regional African American Language (CORAAL) is published by the
Online Resources for African American Language project. This fixture was
sourced from:

<https://huggingface.co/datasets/zsayers/CORAAL>

The original dataset's attribution and license are published by CORAAL:

<https://oraal.github.io/coraal>

```text
Kendall, Tyler and Charlie Farrington. 2023. The Corpus of Regional African
American Language. Version 2023.06. Eugene, OR: The Online Resources for
African American Language Project. https://doi.org/10.7264/1ad5-6t35
```

This fixture is distributed under Creative Commons
Attribution-NonCommercial-ShareAlike 4.0 International. Preserve the
attribution, license URL, trimming modification notice, and NonCommercial and
ShareAlike terms:

<https://creativecommons.org/licenses/by-nc-sa/4.0/>

## Edinburgh Noisy Speech Database

Files and status:

- `48000/edinburgh_56_speaker_p257_290/input.wav` is the source noisy-speech
  recording.
- `48000/edinburgh_56_speaker_p257_290/expected.wav` is a modified version
  produced from `input.wav` by RE-USE inference.
- `48000/edinburgh_56_speaker_p232_177/input.wav` is the source noisy-speech
  recording; `ground_truth.wav` is its paired clean reference recording.
- `48000/edinburgh_56_speaker_p257_426/input.wav` is the source noisy-speech
  recording; `ground_truth.wav` is its paired clean reference recording.
- `48000/edinburgh_56_speaker_merged_12e1f83c/input.wav` and
  `ground_truth.wav` are the corresponding concatenated noisy and clean
  recordings. The `12e1f83c` suffix is the first eight hexadecimal characters
  of the SHA-256 hash of the newline-delimited ordered clean sample IDs below.
  Their SHA-256 hashes are respectively
  `0e3e9f49835d9e923fa6e524244108272cca5c6d7cb70e4091d03e960223cf4a`
  and `26b629801a1d236a576cf83c3162c8ea7d9b938a2c99cb67faf0bfc5d903559c`.

The clean samples concatenated for
`48000/edinburgh_56_speaker_merged_12e1f83c/ground_truth.wav`, in order, are:

```text
p232_250
p257_063
p232_084
p232_066
p257_393
p232_195
p232_389
p232_047
p257_355
p232_237
p232_298
p232_384
p232_176
p232_003
p232_175
p232_365
p257_344
p257_317
p232_332
p232_348
p257_096
p232_333
p232_021
p232_305
p257_074
p232_028
p232_353
p232_391
p257_009
p232_270
p257_387
p232_083
p232_194
p257_204
p257_028
p257_326
p232_123
p257_276
p257_301
p232_400
p257_232
p232_137
p257_413
p232_078
p257_391
p257_395
p232_317
p257_124
```

Source and attribution:

```text
Valentini-Botinhao, Cassia. (2017).
Noisy speech database for training speech enhancement algorithms and TTS models, 2016 [sound].
University of Edinburgh. School of Informatics. Centre for Speech Technology Research (CSTR).
https://doi.org/10.7488/ds/2117
```

Both files are distributed under Creative Commons Attribution 4.0
International. Preserve the attribution, license URL, and modification notice:

<https://creativecommons.org/licenses/by/4.0/>
