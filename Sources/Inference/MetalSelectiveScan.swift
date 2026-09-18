// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXFast

enum MetalSelectiveScanError: LocalizedError {
    case invalidShape(String)

    var errorDescription: String? {
        switch self {
        case .invalidShape(let message):
            return message
        }
    }
}

enum MetalSelectiveScan {

    private static let header = """
    inline float selective_scan_sigmoid(float x) {
        return 1.0f / (1.0f + exp(-x));
    }

    inline float selective_scan_silu(float x) {
        return x * selective_scan_sigmoid(x);
    }

    // Softplus uses the same expression as MLX's eager graph; selective-scan
    // parity tests cover the fused implementation.
    // That graph is 3 separate dispatches per Mamba call (exp, +1, log);
    // folding it in here lets the scan kernel consume the raw `dtProj(dt)`
    // output and do the transform per thread inline with the scan work.
    inline float selective_scan_softplus(float x) {
        return log(1.0f + exp(x));
    }
    """

    // Per-thread register layout (see docs/kernel-optimization.md § Fusion decisions):
    //   x[n]     — the SSM hidden state, updated every timestep.
    //   a_reg[n] — slice `-exp(A_log[d, :])`, fused from raw A_log and
    //              hoisted out of the L loop (avoids L*N reloads under Metal
    //              aliasing rules).
    //   d_reg    — Dparam[d], likewise hoisted out of the L loop.
    //
    // Delta (`delta_raw`) is consumed pre-softplus: softplus runs per L step
    // inside the kernel (see docs/kernel-optimization.md).
    //
    private static let fixed16Source = """
    uint tid = thread_position_in_grid.x;

    int B_size = delta_raw_shape[0];
    int L_size = delta_raw_shape[1];
    int D_size = delta_raw_shape[2];
    constexpr int N_size = 16;

    uint total_bd = B_size * D_size;
    if (tid >= total_bd) {
        return;
    }

    uint b = tid / D_size;
    uint d = tid % D_size;

    float x[N_size];
    float a_reg[N_size];
    for (uint n = 0; n < N_size; ++n) {
        x[n] = 0.0f;
        // Fuse the `-exp(A_log)` MLX op into the per-thread init.
        a_reg[n] = -fast::exp(A_log[d * N_size + n]);
    }
    float d_reg = Dparam[d];

    uint base_bln = b * (L_size * N_size);
    uint base_bld = b * (L_size * D_size);

    for (uint i = 0; i < L_size; ++i) {
        uint offset_bld_i = base_bld + i * D_size + d;
        uint offset_bln_i = base_bln + i * N_size;

        // Fuse softplus (`log(1 + exp(x))`) inline; the kernel now
        // consumes the raw `dtProj(dt)` output directly.
        float delta_val = selective_scan_softplus(delta_raw[offset_bld_i]);
        float u_val = u[offset_bld_i];
        float dBu_base = delta_val * u_val;

        float y = 0.0f;
        for (uint n = 0; n < N_size; ++n) {
            float b_val = Bseq[offset_bln_i + n];
            float dA = fast::exp(delta_val * a_reg[n]);
            float dBu = dBu_base * b_val;
            float x_new = dA * x[n] + dBu;
            x[n] = x_new;
            y += x_new * Cseq[offset_bln_i + n];
        }

        y += u_val * d_reg;
        y *= selective_scan_silu(z[offset_bld_i]);
        out[offset_bld_i] = y;
    }
    """

    private static let fixed16Kernel = MLXFast.metalKernel(
        name: "speechlens_selective_scan_fixed16",
        inputNames: ["delta_raw", "A_log", "Bseq", "Cseq", "u", "Dparam", "z"],
        outputNames: ["out"],
        source: fixed16Source,
        header: header,
        ensureRowContiguous: true
    )

    // Strict mode keeps the same fixed-16 recurrence and dispatch geometry,
    // while making the numerical choices from the phase-parity candidate
    // explicit: stable softplus, direct-division SiLU, ordinary exp for the
    // learned decay, and a bounded base-2 polynomial with IEEE exponent-field
    // scaling for the per-step decay.
    private static let strictHeader = """
    inline float strict_scan_softplus(float x) {
        return max(x, 0.0f) + log1p(exp(-abs(x)));
    }

    inline float strict_scan_silu(float x) {
        return x / (1.0f + exp(-x));
    }

    inline float strict_bitcast_exp(float x) {
        float y = x * 1.4426950408889634f;
        float k_f = rint(y);
        int k = (int)k_f;
        float f = y - k_f;
        float p = 1.5465313e-4f;
        p = p * f + 1.3395279e-3f;
        p = p * f + 9.6180400e-3f;
        p = p * f + 5.5503407e-2f;
        p = p * f + 2.4022651e-1f;
        p = p * f + 6.9314720e-1f;
        p = p * f + 1.0f;
        return (k >= -126)
            ? as_type<float>(as_type<int>(p) + (k << 23))
            : 0.0f;
    }
    """

    private static let strictSource = """
    #pragma clang fp contract(off)

    uint tid = thread_position_in_grid.x;

    int B_size = delta_raw_shape[0];
    int L_size = delta_raw_shape[1];
    int D_size = delta_raw_shape[2];
    constexpr int N_size = 16;

    uint total_bd = B_size * D_size;
    if (tid >= total_bd) return;

    uint b = tid / D_size;
    uint d = tid % D_size;

    float x[N_size];
    float a_reg[N_size];
    for (uint n = 0; n < N_size; ++n) {
        x[n] = 0.0f;
        a_reg[n] = -exp(A_log[d * N_size + n]);
    }
    float d_reg = Dparam[d];

    uint base_bln = b * (L_size * N_size);
    uint base_bld = b * (L_size * D_size);

    device const float* delta_ptr = delta_raw + base_bld + d;
    device const float* u_ptr = u + base_bld + d;
    device const float* z_ptr = z + base_bld + d;
    device float* out_ptr = out + base_bld + d;
    device const float* B_ptr = Bseq + base_bln;
    device const float* C_ptr = Cseq + base_bln;

    for (uint i = 0; i < L_size; ++i) {
        float delta_val = strict_scan_softplus(*delta_ptr);
        float u_val = *u_ptr;

        float y = 0.0f;
        #pragma unroll 16
        for (uint n = 0; n < N_size; ++n) {
            float b_val = B_ptr[n];
            float dA = strict_bitcast_exp(delta_val * a_reg[n]);
            float dBu = (delta_val * b_val) * u_val;
            float x_new = dA * x[n] + dBu;
            x[n] = x_new;
            y += x_new * C_ptr[n];
        }

        y += u_val * d_reg;
        y *= strict_scan_silu(*z_ptr);
        *out_ptr = y;

        delta_ptr += D_size;
        u_ptr += D_size;
        z_ptr += D_size;
        out_ptr += D_size;
        B_ptr += N_size;
        C_ptr += N_size;
    }
    """

    private static let strictKernel = MLXFast.metalKernel(
        name: "speechlens_selective_scan_fixed16_fast_bitcast_scalar",
        inputNames: ["delta_raw", "A_log", "Bseq", "Cseq", "u", "Dparam", "z"],
        outputNames: ["out"],
        source: strictSource,
        header: strictHeader,
        ensureRowContiguous: true
    )

    /// Raw inputs — softplus(delta_raw) and -exp(A_log) are fused into the
    /// kernel. Callers should pass `dtProj(dt)` (pre-softplus) and
    /// `A_log` (pre-negation-and-exp) directly.
    static func validateModelLayout(
        aLogShape: [Int],
        dShape: [Int],
        xProjWeightShape: [Int],
        dtProjWeightShape: [Int]
    ) throws {
        guard aLogShape == [256, reUseMambaStateSize] else {
            throw MetalSelectiveScanError.invalidShape(
                "A_log must have shape [256, \(reUseMambaStateSize)] for the fixed-16 Metal scan"
            )
        }
        guard dShape == [256] else {
            throw MetalSelectiveScanError.invalidShape("D must have shape [256] for the fixed-16 Metal scan")
        }
        guard xProjWeightShape == [36, 256] else {
            throw MetalSelectiveScanError.invalidShape(
                "xProj.weight must have shape [36, 256] for the fixed-16 Metal scan"
            )
        }
        guard dtProjWeightShape == [256, 4] else {
            throw MetalSelectiveScanError.invalidShape(
                "dtProj.weight must have shape [256, 4] for the fixed-16 Metal scan"
            )
        }
    }

    static func validateInputShapes(
        deltaRaw: MLXArray,
        A_log: MLXArray,
        B: MLXArray,
        C: MLXArray,
        u: MLXArray,
        D: MLXArray,
        z: MLXArray
    ) throws {
        guard deltaRaw.shape.count == 3, u.shape == deltaRaw.shape else {
            throw MetalSelectiveScanError.invalidShape("delta_raw and u must both have shape [B, L, D]")
        }
        guard A_log.shape.count == 2 else {
            throw MetalSelectiveScanError.invalidShape("A_log must have shape [D, N]")
        }
        guard B.shape.count == 3, C.shape == B.shape else {
            throw MetalSelectiveScanError.invalidShape("B and C must both have shape [B, L, N]")
        }
        guard D.shape.count == 1 else {
            throw MetalSelectiveScanError.invalidShape("D must have shape [D]")
        }
        guard z.shape == deltaRaw.shape else {
            throw MetalSelectiveScanError.invalidShape("z must have shape [B, L, D]")
        }

        let batch = deltaRaw.shape[0]
        let seqLen = deltaRaw.shape[1]
        let dSize = deltaRaw.shape[2]
        let nSize = A_log.shape[1]

        guard A_log.shape[0] == dSize else {
            throw MetalSelectiveScanError.invalidShape("A_log first dimension must equal D")
        }
        guard B.shape[0] == batch, B.shape[1] == seqLen, B.shape[2] == nSize else {
            throw MetalSelectiveScanError.invalidShape("B must have shape [B, L, N]")
        }
        guard D.shape[0] == dSize else {
            throw MetalSelectiveScanError.invalidShape("D length must equal D")
        }
        guard nSize == reUseMambaStateSize else {
            throw MetalSelectiveScanError.invalidShape(
                "selective_scan requires RE-USE model nState \(reUseMambaStateSize)"
            )
        }
    }

    /// Runs the fixed-16 kernel after model-load validation establishes its
    /// tensor contract. Runtime Mamba tensors are derived from that contract.
    static func run(
        deltaRaw: MLXArray,
        A_log: MLXArray,
        B: MLXArray,
        C: MLXArray,
        u: MLXArray,
        D: MLXArray,
        z: MLXArray,
        mode: InferenceMode = .standard
    ) -> MLXArray {
        let batch = deltaRaw.shape[0]
        let seqLen = deltaRaw.shape[1]
        let dSize = deltaRaw.shape[2]
        let totalThreads = max(1, batch * dSize)
        let threadGroup = min(256, totalThreads)
        let kernel = mode == .strict ? strictKernel : fixed16Kernel
        let outputs = kernel(
            [deltaRaw, A_log, B, C, u, D, z],
            grid: (totalThreads, 1, 1),
            threadGroup: (threadGroup, 1, 1),
            outputShapes: [[batch, seqLen, dSize]],
            outputDTypes: [.float32]
        )
        return outputs[0]
    }
}
