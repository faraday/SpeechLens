// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXNN

class BidirectionalMamba: Module, UnaryLayer {
    let forward: Mamba
    let backward: Mamba
    let outputProj: Linear
    let norm: LayerNorm
    
    init(dModel: Int, mode: InferenceMode = .standard) {
        self.forward = Mamba(dModel: dModel, mode: mode)
        self.backward = Mamba(dModel: dModel, mode: mode)
        self.outputProj = Linear(2 * dModel, dModel)
        self.norm = LayerNorm(dimensions: dModel)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // PyTorch MambaBlock.forward:
        //   out_fw = forward_blocks(x) + x
        //   out_bw = backward_blocks(flip(x)) + flip(x)
        //   out_bw = flip(out_bw)
        //   return norm(output_proj(cat([out_fw, out_bw], -1)))

        // Reverse along axis 1 using a negative-stride view (zero-copy).
        let reversedX = x[0..., .stride(by: -1), 0...]

        let outFw = forward(x) + x
        let outBw = backward(reversedX) + reversedX
        let outBwReversed = outBw[0..., .stride(by: -1), 0...]

        let combined = MLX.concatenated([outFw, outBwReversed], axis: -1)
        return norm(outputProj(combined))
    }
}

class TFMambaBlock: Module, UnaryLayer {
    let timeMamba: BidirectionalMamba
    let freqMamba: BidirectionalMamba
    
    init(hidFeature: Int, mode: InferenceMode = .standard) {
        self.timeMamba = BidirectionalMamba(dModel: hidFeature, mode: mode)
        self.freqMamba = BidirectionalMamba(dModel: hidFeature, mode: mode)
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [B, T, F, C] (MLX convention)
        let (b, t, f, c) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])
        
        // Treat each frequency bin as an independent time sequence.
        var y = x.transposed(0, 2, 1, 3).reshaped(b * f, t, c)
        y = timeMamba(y) + y
        
        // Treat each time step as an independent frequency sequence.
        y = y.reshaped(b, f, t, c).transposed(0, 2, 1, 3).reshaped(b * t, f, c)
        y = freqMamba(y) + y
        
        // Back to [B, T, F, C]
        y = y.reshaped(b, t, f, c)
        return y
    }
}
