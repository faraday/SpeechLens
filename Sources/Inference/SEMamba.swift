// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXNN

// SAFETY: The non-Sendable MLX model is confined to MambaEnhancer.
extension SEMamba: @unchecked Sendable {}

class SEMamba: Module {
    let denseEncoder: DenseEncoder
    let tfMamba: [TFMambaBlock]
    let maskDecoder: MagDecoder
    let phaseDecoder: PhaseDecoder

    init(numBlocks: Int = 30, mode: InferenceMode = .standard) {
        self.denseEncoder = DenseEncoder()
        self.tfMamba = (0..<numBlocks).map { _ in
            TFMambaBlock(hidFeature: 64, mode: mode)
        }
        self.maskDecoder = MagDecoder(hidFeature: 64, outputChannel: 1)
        self.phaseDecoder = PhaseDecoder(hidFeature: 64, outputChannel: 1)
        super.init()
    }

    func callAsFunction(_ mag: MLXArray, _ pha: MLXArray) -> (MLXArray, MLXArray) {
        // Convert `[B, F, T]` inputs to MLX's `[B, T, F, C]` layout.
        let mag = mag.transposed(0, 2, 1)
        let pha = pha.transposed(0, 2, 1)
        
        var x = MLX.stacked([mag, pha], axis: -1)
        
        let (_, t, f, _) = (x.shape[0], x.shape[1], x.shape[2], x.shape[3])
        
        // x: [B, T, F, C]
        // PyTorch F.pad(x, (0, 2, 0, 2)) on [B, 2, T, F] pads F by (0,2) and T by (0,2)
        // In MLX [B, T, F, 2], Axis 1 is T, Axis 2 is F.
        x = MLX.padded(x, widths: [IntOrPair(0), IntOrPair((0, 2)), IntOrPair((0, 2)), IntOrPair(0)])
        
        x = denseEncoder(x)
        for block in tfMamba {
            x = block(x)
        }

        var denoisedMag = maskDecoder(x)
        var denoisedPha = phaseDecoder(x)
        
        // Remove model padding, then restore `[B, F, T]` outputs.
        denoisedMag = denoisedMag[0..., ..<t, ..<f, 0...]
        denoisedPha = denoisedPha[0..., ..<t, ..<f, 0...]
        
        denoisedMag = denoisedMag.squeezed(axis: -1).transposed(0, 2, 1)
        denoisedPha = denoisedPha.squeezed(axis: -1).transposed(0, 2, 1)
        
        return (denoisedMag, denoisedPha)
    }
}
