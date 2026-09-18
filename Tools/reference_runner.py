#!/usr/bin/env python3
# SPDX-License-Identifier: LicenseRef-NVIDIA-One-Way-Noncommercial-NSCLv1

"""Dump intermediate activations from the Python model for parity testing."""

import argparse
import hashlib
import importlib.metadata
import json
import os
import math
import tempfile
from collections import OrderedDict
from pathlib import Path

os.environ.setdefault("CUBLAS_WORKSPACE_CONFIG", ":4096:8")
os.environ.setdefault("OMP_NUM_THREADS", "1")
os.environ.setdefault("MKL_NUM_THREADS", "1")

import torch
import torch.nn as nn
import torch.nn.functional as F
from einops import rearrange
from safetensors.torch import load_file, save_file

EXPECTED_SOURCE_SHA256 = "87a4a970ce9aa79d5d92e71899ab034defcf13d93e5e4393ec0dc7db6d4ec048"
EXPECTED_SOURCE_REVISION = "fe51d6495e49a1b7c28ef6e3a43820f841c944fc"
PROBE_FILENAME = "parity_probes.safetensors"
MANIFEST_FILENAME = "parity_probes.json"
PROBE_LICENSE = "LicenseRef-NVIDIA-One-Way-Noncommercial-NSCLv1"
PROBE_LICENSE_FILE = "../../../LICENSE-NVIDIA-NSCLv1.txt"
SEED = 42
THREAD_COUNT = 1

# Model definitions adapted from NVIDIA RE-USE.
# Mamba is implemented in pure PyTorch for portable CPU parity generation.

class Mamba(nn.Module):
    def __init__(self, d_model, d_state=16, d_conv=4, expand=4, dt_rank="auto"):
        super().__init__()
        self.d_model = d_model
        self.d_state = d_state
        self.d_conv = d_conv
        self.expand = expand
        self.d_inner = int(self.expand * self.d_model)
        self.dt_rank = math.ceil(self.d_model / 16) if dt_rank == "auto" else dt_rank

        self.in_proj = nn.Linear(self.d_model, self.d_inner * 2, bias=False)
        self.conv1d = nn.Conv1d(
            in_channels=self.d_inner,
            out_channels=self.d_inner,
            bias=True,
            kernel_size=d_conv,
            groups=self.d_inner,
            padding=d_conv - 1,
        )
        self.x_proj = nn.Linear(self.d_inner, self.dt_rank + self.d_state * 2, bias=False)
        self.dt_proj = nn.Linear(self.dt_rank, self.d_inner, bias=True)

        A = torch.arange(1, self.d_state + 1, dtype=torch.float32).repeat(self.d_inner, 1)
        self.A_log = nn.Parameter(torch.log(A))
        self.D = nn.Parameter(torch.ones(self.d_inner))
        self.out_proj = nn.Linear(self.d_inner, self.d_model, bias=False)

    def forward(self, x):
        (batch, seqlen, dim) = x.shape
        xz = self.in_proj(x)
        x, z = xz.chunk(2, dim=-1)

        x = x.transpose(1, 2)
        x = self.conv1d(x)[:, :, :seqlen]
        x = F.silu(x)

        x_dbl = self.x_proj(x.transpose(1, 2))
        dt, B, C = x_dbl.split([self.dt_rank, self.d_state, self.d_state], dim=-1)
        delta = self.dt_proj(dt)

        delta = delta.transpose(1, 2)
        u = x
        A = -torch.exp(self.A_log.float())
        D = self.D.float()
        z = z.transpose(1, 2)
        
        y = self.selective_scan_ref(u, delta, A, B.transpose(1, 2), C.transpose(1, 2), D, z)
        return self.out_proj(y.transpose(1, 2))

    def selective_scan_ref(self, u, delta, A, B, C, D, z):
        """Pure PyTorch reference implementation."""
        delta = F.softplus(delta)
        batch, dim, L = u.shape[0], u.shape[1], u.shape[2]
        d_state = A.shape[1]
        
        deltaA = torch.exp(torch.einsum('bdl,dn->bdln', delta, A))
        deltaB_u = torch.einsum('bdl,bnl,bdl->bdln', delta, B, u)
        
        h = torch.zeros(batch, dim, d_state, device=u.device, dtype=u.dtype)
        ys = []
        for i in range(L):
            h = h * deltaA[:, :, i, :] + deltaB_u[:, :, i, :]
            y = torch.einsum('bdn,bn->bd', h, C[:, :, i])
            ys.append(y)
        
        y = torch.stack(ys, dim=2)
        if D is not None: y = y + u * D[..., None]
        if z is not None: y = y * F.silu(z)
        return y

class DenseBlock(nn.Module):
    def __init__(self, hid_feature, depth=4):
        super().__init__()
        self.depth = depth
        self.dense_block = nn.ModuleList()
        for i in range(depth):
            dil = 2 ** i
            dense_conv = nn.Sequential(
                nn.Conv2d(hid_feature * (i + 1), hid_feature, (3, 3), 
                          dilation=(dil, 1), padding=(dil, 1)),
                nn.InstanceNorm2d(hid_feature, affine=True),
                nn.PReLU(hid_feature)
            )
            self.dense_block.append(dense_conv)

    def forward(self, x):
        skip = x
        for i in range(self.depth):
            x = self.dense_block[i](skip)
            skip = torch.cat([x, skip], dim=1)
        return x

class DenseEncoder(nn.Module):
    def __init__(self, input_channel=2, hid_feature=64):
        super().__init__()
        self.dense_conv_1 = nn.Sequential(
            nn.Conv2d(input_channel, hid_feature, (1, 1)),
            nn.InstanceNorm2d(hid_feature, affine=True),
            nn.PReLU(hid_feature)
        )
        self.dense_block = DenseBlock(hid_feature, depth=4)
        self.dense_conv_2 = nn.Sequential(
            nn.Conv2d(hid_feature, hid_feature, (1, 3), stride=(4, 2)),
            nn.InstanceNorm2d(hid_feature, affine=True),
            nn.PReLU(hid_feature)
        )

    def forward(self, x):
        x = self.dense_conv_1(x)
        x = self.dense_block(x)
        x = self.dense_conv_2(x)
        return x

class SPConvTranspose2d(nn.Module):
    def __init__(self, in_channels, out_channels, kernel_size, r=1):
        super().__init__()
        self.pad1 = nn.ConstantPad2d((1, 1, 0, 0), value=0.)
        self.out_channels = out_channels
        self.conv = nn.Conv2d(in_channels, out_channels * r, kernel_size=kernel_size, stride=(1, 1))
        self.r = r

    def forward(self, x):
        x = self.pad1(x)
        out = self.conv(x)
        batch_size, nchannels, H, W = out.shape
        out = out.view((batch_size, self.r, nchannels // self.r, H, W))
        out = out.permute(0, 2, 3, 4, 1).contiguous().view((batch_size, nchannels // self.r, H, -1))
        return out

class MagDecoder(nn.Module):
    def __init__(self, hid_feature=64, output_channel=1):
        super().__init__()
        self.dense_block = DenseBlock(hid_feature, depth=4)
        self.up_conv1 = nn.Sequential(
            SPConvTranspose2d(hid_feature, hid_feature, (1, 3), 2),
            nn.InstanceNorm2d(hid_feature, affine=True),
            nn.PReLU(hid_feature)
        )
        self.up_conv2 = nn.Sequential(
            SPConvTranspose2d(hid_feature, hid_feature, (1, 3), 4),
            nn.InstanceNorm2d(hid_feature, affine=True),
            nn.PReLU(hid_feature)
        )
        self.final_conv = nn.Conv2d(hid_feature, output_channel, (1, 1))

    def forward(self, x):
        x = self.dense_block(x)
        x = self.up_conv1(x)
        x = self.up_conv2(x.permute(0, 1, 3, 2)).permute(0, 1, 3, 2)
        return self.final_conv(x)

class PhaseDecoder(nn.Module):
    """Mirrors RE-USE PhaseDecoder: shared trunk + phase_conv_r/i + atan2."""
    def __init__(self, hid_feature=64, output_channel=1):
        super().__init__()
        self.dense_block = DenseBlock(hid_feature, depth=4)
        self.up_conv1 = nn.Sequential(
            SPConvTranspose2d(hid_feature, hid_feature, (1, 3), 2),
            nn.InstanceNorm2d(hid_feature, affine=True),
            nn.PReLU(hid_feature)
        )
        self.up_conv2 = nn.Sequential(
            SPConvTranspose2d(hid_feature, hid_feature, (1, 3), 4),
            nn.InstanceNorm2d(hid_feature, affine=True),
            nn.PReLU(hid_feature)
        )
        self.phase_conv_r = nn.Conv2d(hid_feature, output_channel, (1, 1))
        self.phase_conv_i = nn.Conv2d(hid_feature, output_channel, (1, 1))

    def forward(self, x):
        x = self.dense_block(x)
        x = self.up_conv1(x)
        x = self.up_conv2(x.permute(0, 1, 3, 2)).permute(0, 1, 3, 2)
        x_r = self.phase_conv_r(x)
        x_i = self.phase_conv_i(x)
        return torch.atan2(x_i, x_r)

class MambaBlock(nn.Module):
    def __init__(self, d_model):
        super().__init__()
        self.forward_blocks = Mamba(d_model=d_model)
        self.backward_blocks = Mamba(d_model=d_model)
        self.output_proj = nn.Linear(2 * d_model, d_model)
        self.norm = nn.LayerNorm(d_model)

    def forward(self, x):
        out_fw = self.forward_blocks(x) + x
        out_bw = self.backward_blocks(torch.flip(x, dims=[1])) + torch.flip(x, dims=[1])
        out_bw = torch.flip(out_bw, dims=[1])
        out = torch.cat([out_fw, out_bw], dim=-1)
        return self.norm(self.output_proj(out))

class TFMambaBlock(nn.Module):
    def __init__(self, hid_feature=64):
        super().__init__()
        self.time_mamba = MambaBlock(d_model=hid_feature)
        self.freq_mamba = MambaBlock(d_model=hid_feature)

    def forward(self, x):
        b, c, t, f = x.size()
        x = x.permute(0, 3, 2, 1).contiguous().view(b * f, t, c)
        x = self.time_mamba(x) + x
        x = x.view(b, f, t, c).permute(0, 2, 1, 3).contiguous().view(b * t, f, c)
        x = self.freq_mamba(x) + x
        x = x.view(b, t, f, c).permute(0, 3, 1, 2)
        return x

class SEMamba(nn.Module):
    def __init__(self, num_blocks=4):
        super().__init__()
        self.dense_encoder = DenseEncoder()
        self.TSMamba = nn.ModuleList([TFMambaBlock() for _ in range(num_blocks)])
        self.mask_decoder = MagDecoder()
        self.phase_decoder = PhaseDecoder()

    def forward(self, mag, pha):
        mag = rearrange(mag, 'b f t -> b t f').unsqueeze(1)
        pha = rearrange(pha, 'b f t -> b t f').unsqueeze(1)
        x = torch.cat((mag, pha), dim=1)
        B, C, T, F = x.shape
        x = torch.cat((x, torch.zeros(B, C, T, 2)), dim=-1)
        x = torch.cat((x, torch.zeros(B, C, 2, F + 2)), dim=-2)
        
        x = self.dense_encoder(x)
        for block in self.TSMamba:
            x = block(x)
        
        mask = rearrange(self.mask_decoder(x), 'b c t f -> b f t c').squeeze(-1)
        phase_mask = rearrange(self.phase_decoder(x), 'b c t f -> b f t c').squeeze(-1)
        return mask[:, :F, :T], phase_mask[:, :F, :T]

def parse_args():
    parser = argparse.ArgumentParser(
        description="Generate SpeechLens parity probes from upstream RE-USE weights."
    )
    parser.add_argument(
        "--weights",
        help="Path to upstream model.safetensors. Defaults to SPEECHLENS_SOURCE_WEIGHTS.",
    )
    parser.add_argument(
        "--output-dir",
        default="Tests/Fixtures/Reference",
        help="Directory for parity_probes.safetensors.",
    )
    args = parser.parse_args()
    args.weights = args.weights or os.environ.get("SPEECHLENS_SOURCE_WEIGHTS")
    if not args.weights:
        parser.error(
            "provide --weights <model.safetensors> or set SPEECHLENS_SOURCE_WEIGHTS"
        )
    if not os.path.isfile(args.weights):
        parser.error(f"source weights not found at {args.weights}")
    return args


def sha256_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def configure_determinism():
    torch.set_num_threads(THREAD_COUNT)
    torch.set_num_interop_threads(THREAD_COUNT)
    torch.use_deterministic_algorithms(True)
    torch.manual_seed(SEED)


def normalized_state_dict(state_dict):
    keys = list(state_dict)
    if not keys:
        raise RuntimeError("source weights contain no tensors")

    prefixed = [key.startswith("SEMamba.") for key in keys]
    if any(prefixed) and not all(prefixed):
        raise RuntimeError("source weights mix SEMamba-prefixed and unprefixed keys")

    if all(prefixed):
        state_dict = OrderedDict(
            (key.removeprefix("SEMamba."), value) for key, value in state_dict.items()
        )

    non_finite = [
        key
        for key, value in state_dict.items()
        if value.is_floating_point() and not torch.isfinite(value).all().item()
    ]
    if non_finite:
        preview = ", ".join(non_finite[:5])
        raise RuntimeError(f"source weights contain non-finite tensors: {preview}")

    return state_dict


def validate_probes(probes):
    for name, value in probes.items():
        if not value.is_floating_point():
            raise RuntimeError(f"probe {name} has unsupported dtype {value.dtype}")
        if not torch.isfinite(value).all().item():
            raise RuntimeError(f"probe {name} contains non-finite values")


def package_versions():
    return {
        name: importlib.metadata.version(name)
        for name in (
            "einops",
            "numpy",
            "opt-einsum",
            "packaging",
            "safetensors",
            "torch",
        )
    }


def write_outputs(output_dir, probes, weights_sha256):
    output_path = Path(output_dir) / PROBE_FILENAME
    manifest_path = Path(output_dir) / MANIFEST_FILENAME
    runner_path = Path(__file__).resolve()

    ordered_probes = OrderedDict(
        (name, probes[name].detach().cpu().contiguous()) for name in sorted(probes)
    )
    validate_probes(ordered_probes)

    with tempfile.TemporaryDirectory(dir=output_dir, prefix=".parity-probes-") as temp_dir:
        temp_output = Path(temp_dir) / PROBE_FILENAME
        temp_manifest = Path(temp_dir) / MANIFEST_FILENAME
        save_file(ordered_probes, temp_output)
        output_sha256 = sha256_file(temp_output)

        manifest = {
            "determinism": {
                "device": "cpu",
                "seed": SEED,
                "thread_count": THREAD_COUNT,
                "torch_deterministic_algorithms": True,
            },
            "format_version": 2,
            "packages": package_versions(),
            "probes": {
                name: {
                    "dtype": str(value.dtype).removeprefix("torch."),
                    "shape": list(value.shape),
                }
                for name, value in ordered_probes.items()
            },
            "runner_sha256": sha256_file(runner_path),
            "source": {
                "repository": "nvidia/RE-USE",
                "revision": EXPECTED_SOURCE_REVISION,
                "weights_sha256": weights_sha256,
            },
            "artifact": {
                "filename": PROBE_FILENAME,
                "license": PROBE_LICENSE,
                "license_file": PROBE_LICENSE_FILE,
                "license_note": (
                    "Conservative distribution classification for numerical reference "
                    "data generated by the NVIDIA RE-USE model."
                ),
                "sha256": output_sha256,
            },
        }
        temp_manifest.write_text(
            json.dumps(manifest, indent=2, sort_keys=True) + "\n",
            encoding="utf-8",
        )

        os.replace(temp_output, output_path)
        os.replace(temp_manifest, manifest_path)

    return output_path, manifest_path


def main():
    args = parse_args()
    weights_path = os.path.abspath(args.weights)
    output_dir = os.path.abspath(args.output_dir)
    os.makedirs(output_dir, exist_ok=True)

    configure_determinism()
    weights_sha256 = sha256_file(weights_path)
    if weights_sha256 != EXPECTED_SOURCE_SHA256:
        raise RuntimeError(
            "source weights SHA-256 mismatch: "
            f"expected {EXPECTED_SOURCE_SHA256}, got {weights_sha256}"
        )

    model = SEMamba(num_blocks=30).cpu()

    state_dict = normalized_state_dict(load_file(weights_path, device="cpu"))
    model.load_state_dict(state_dict, strict=True)
    model.eval()

    # Reset after model construction so initialization cannot consume the probe
    # random stream. Inputs are `[B, F, T]` STFT snippets.
    torch.manual_seed(SEED)
    mag = torch.randn(1, 161, 64, device="cpu")
    pha = torch.randn(1, 161, 64, device="cpu")

    probes = {}

    def hook_fn(name):
        def hook(module, input, output):
            probes[name] = output.detach()
        return hook

    model.dense_encoder.register_forward_hook(hook_fn("encoder_out"))
    model.TSMamba[0].register_forward_hook(hook_fn("block_0_out"))
    model.TSMamba[29].register_forward_hook(hook_fn("block_29_out"))

    with torch.no_grad():
        mask, phase = model(mag, pha)
        probes["final_mask"] = mask
        probes["final_phase"] = phase
        probes["input_mag"] = mag
        probes["input_pha"] = pha

    output_path, manifest_path = write_outputs(output_dir, probes, weights_sha256)
    print(f"Reference activations saved to {output_path}")
    print(f"Reference manifest saved to {manifest_path}")

if __name__ == "__main__":
    main()
