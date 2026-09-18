// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXNN

let reUseMambaStateSize = 16

class Mamba: Module, UnaryLayer {
    let inProj: Linear
    let conv1d: Conv1d
    let xProj: Linear
    let dtProj: Linear
    
    // These stored-property names are part of the converted weight-key contract.
    var A_log: MLXArray
    var D: MLXArray
    let outProj: Linear
    let mode: InferenceMode

    init(dModel: Int, dConv: Int = 4, expand: Int = 4, mode: InferenceMode = .standard) {
        self.mode = mode
        let dInner = Int(expand * dModel)
        let dtRank = Int(ceil(Double(dModel) / 16.0))
        
        self.inProj = Linear(dModel, dInner * 2, bias: false)
        self.conv1d = Conv1d(inputChannels: dInner, outputChannels: dInner, kernelSize: dConv, padding: dConv - 1, groups: dInner, bias: true)
        self.xProj = Linear(dInner, dtRank + reUseMambaStateSize * 2, bias: false)
        self.dtProj = Linear(dtRank, dInner, bias: true)
        
        self.A_log = MLX.zeros([dInner, reUseMambaStateSize])
        self.D = MLX.ones([dInner])
        self.outProj = Linear(dInner, dModel, bias: false)
        
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let seqLen = x.shape[1]
        
        let xz = inProj(x)
        let split = xz.split(indices: [xz.shape[2] / 2], axis: -1)
        var innerX = split[0]
        let innerZ = split[1]
        
        // Conv1d — custom Metal kernel for the causal depthwise shape (one dispatch /
        // one graph node). Falls back to MLXNN.Conv1d on failure or when
        // SPEECHLENS_DISABLE_METAL_CONV1D=1. See docs/kernel-optimization.md.
        if MetalCausalConv1d.isEnabled, let convBias = conv1d.bias {
            do {
                innerX = try MetalCausalConv1d.run(
                    x: innerX,
                    weight: conv1d.weight,
                    bias: convBias
                )
            } catch {
                SpeechLensLog.mamba.warning(
                    "MetalCausalConv1d failed, falling back to MLXNN.Conv1d: \(String(describing: error), privacy: .private)"
                )
                innerX = conv1d(innerX)
                innerX = innerX[0..., ..<seqLen, 0...]
            }
        } else {
            innerX = conv1d(innerX)
            innerX = innerX[0..., ..<seqLen, 0...]
        }
        // MLXNN.silu fuses `x * sigmoid(x)` into one dispatch, avoiding a
        // separate graph node at each of the 120 Mamba call sites per chunk.
        innerX = MLXNN.silu(innerX)
        
        let x_dbl = xProj(innerX)
        let nState = A_log.shape[1]
        let dtRank = x_dbl.shape[2] - (nState * 2)
        
        let splitSSM = x_dbl.split(indices: [dtRank, dtRank + nState], axis: -1)
        let dt = splitSSM[0]
        let B = splitSSM[1]
        let C = splitSSM[2]
        
        // Raw outputs of dtProj; softplus and -exp(A_log) are fused into
        // the fixed-16 Metal kernel.
        let deltaRaw = dtProj(dt)
        let y = MetalSelectiveScan.run(
            deltaRaw: deltaRaw,
            A_log: A_log,
            B: B,
            C: C,
            u: innerX,
            D: D,
            z: innerZ,
            mode: mode
        )
        
        return outProj(y)
    }

}
