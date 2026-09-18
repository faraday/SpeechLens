# Model Artifacts

SpeechLens source code and model weights are separate artifacts. Do not assume
that the source-code license applies to downloaded or converted model weights.

## Artifact Locations

| Artifact | Used by | In this Git repo | External location |
| --- | --- | --- | --- |
| `model_mlx.safetensors` | Swift runtime inference | No | `faraday/re-use-mlx` on Hugging Face |
| `conversion-manifest.json` | app checksum validation and release metadata | No | `faraday/re-use-mlx` on Hugging Face |
| NVIDIA RE-USE `model.safetensors` | offline conversion and parity generation | No | `nvidia/RE-USE` on Hugging Face |
| `Tests/Fixtures/Reference/parity_probes.safetensors` | small parity test probes | Yes | None |

“In this Git repo” means tracked by the SpeechLens source repository. Runtime
weights are intentionally not committed to Git, but the current converted
artifacts are hosted separately on Hugging Face.

## Runtime Weight Resolution

The CLI resolves converted MLX weights in this order:

1. `--weights /path/to/model_mlx.safetensors`
2. `SPEECHLENS_WEIGHTS`
3. `~/Library/Application Support/SpeechLens/Models/model_mlx.safetensors`
4. `./model_mlx.safetensors`

Model-backed tests use `SPEECHLENS_TEST_WEIGHTS` or the app cache path.

## CLI Diagnostic Reports

Pass `--diagnostics-out /path/to/report.json` to write a sanitized JSON report
while processing. The report is updated as the operation advances and records
its terminal completed, failed, or cancelled outcome without changing stderr
output or the command's exit status.

The app and CLI emit the same schema-version-2 report format. Version-1 reports
and app snapshots are intentionally unsupported; the app discards an old or
unreadable latest-operation snapshot on load.

Reports contain environment and media-format facts, processing settings, stable
failure codes, and timing. They never contain audio, file names or paths,
weight paths, raw error descriptions, or arbitrary logs. Parsing, settings
validation, and weight resolution complete before recording begins, so those
early failures use the normal CLI error and do not produce a report.

## App Cache

The app stores downloaded runtime weights at:

```text
~/Library/Application Support/SpeechLens/Models/model_mlx.safetensors
```

The expected SHA-256 is pinned in the human-readable
`Sources/App/ModelArtifact.swift` descriptor, rather than being trusted from
the downloaded manifest alone. A default cached model is ready only when the
model and adjacent manifest both exist, the manifest names the source-pinned
checksum, and the actual model bytes match that checksum. Missing, malformed,
or mismatched metadata fails closed as an unverified cache.

Downloads are staged and verified before cache replacement. A failed refresh
does not remove a previously valid cached model. The app uses only this pinned,
verified artifact and downloads it automatically when absent. Custom weights
remain a CLI-only capability. Runtime weights must retain SpeechLens's fixed
30-block RE-USE model layout with Mamba `d_state=16`; incompatible weights are
rejected during model initialization before inference begins.

## Current Converted Weights

The current app code points at:

```text
Repository: faraday/re-use-mlx
Revision:   07bc44c152c5f9f665d2474cf1f5b69edc7cae14
File:       model_mlx.safetensors
SHA-256:    d1158502eaf39d0b11d097177160ce3804454653c5d14d17921b6c274ca53237
```

The converted weights are derived from `nvidia/RE-USE` and are intended for MLX
and MLX Swift inference workflows on Apple Silicon.

## Licensing

The upstream `nvidia/RE-USE` Hugging Face model card identifies the model as
released under the NVIDIA One-Way Noncommercial License (NSCLv1). The converted
`faraday/re-use-mlx` model card also lists the converted weights under
`nvidia-one-way-noncommercial-license-nsclv1` and states that use is limited to
non-commercial research and educational purposes.

Practical consequences:

1. A permissive source-code license for SpeechLens would not make the model
   weights permissively licensed.
2. Release artifacts should not bundle model weights unless the model license
   allows that distribution path.
3. Public docs and release notes should describe model weights as separately
   licensed artifacts.
4. Users are responsible for checking whether their intended use is permitted by
   the model license.

Relevant model pages:

- <https://huggingface.co/nvidia/RE-USE>
- <https://huggingface.co/faraday/re-use-mlx>

## Converting Weights

To convert upstream Safetensors weights for the Swift runtime:

```bash
swift run WeightPort \
  --input /absolute/path/to/source/model.safetensors \
  --output /absolute/path/to/model_mlx.safetensors
```

If `--input` is omitted, `WeightPort` reads `SPEECHLENS_SOURCE_WEIGHTS`.

## Generating Parity Probes

A parity probe is a small set of reference tensors generated from the upstream
model for fixed test inputs. `WeightParityTests` compare Swift/MLX intermediate
outputs against these tensors to catch layer-level numerical regressions. Parity
probes are test fixtures; they are not runtime model weights and cannot be used
to run inference.

The probes are generated by the offline PyTorch reference implementation and
consumed as validation oracles by the MLX tests; they are not MLX runtime
artifacts. SpeechLens conservatively distributes the Safetensors probe under
NVIDIA NSCLv1. Its adjacent Apache-2.0 manifest records that license, the local
license-file path, source revision, checksums, tool versions, and deterministic
generation settings.

The Python reference runner is an offline CPU-only parity oracle. In this
context, “oracle” means a trusted comparison implementation: the PyTorch
reference path running the original NVIDIA RE-USE weights. It is used to
generate expected tensors for tests and is not part of runtime inference.

```bash
uv sync --locked
uv run python Tools/reference_runner.py \
  --weights /absolute/path/to/source/model.safetensors \
  --output-dir Tests/Fixtures/Reference
```

The generated manifest records source revision, checksums, tool versions,
deterministic execution settings, and probe schema.
