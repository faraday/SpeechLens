# URGENT 2024 `fileid_26119`

- `input.wav`: noisy URGENT validation input, mono 16 kHz Int16 WAV.
- `expected.wav`: inference-derived reference adaptation, mono 16 kHz Float32 WAV.
- `ground_truth.wav`: clean URGENT oracle formerly stored as `expected.wav`.

The NVIDIA reference was generated with the pinned NVIDIA RE-USE chunk-inference
path on NVIDIA L4 using a 10-second chunk, `hop_length_portion=1.0` (zero
overlap), and no sample-rate conversion. The benchmark adapter writes Float32
PCM WAV directly.

SHA-256:

- `input.wav`: `dd844b5703ca47653d7d0d7f9c9e8417001cd21fc2a445811b909e057cf5e170`
- `expected.wav`: `8c1cf7edefc06350197a5d084f968fe1717bd79976b666c59860060fea46328a`
- `ground_truth.wav`: `de571ed4d391c39a0972f3725516d36341d81303be00126c3544f321ccafcc2d`

See `docs/fixtures.md` for source provenance, licensing, and citation details.
