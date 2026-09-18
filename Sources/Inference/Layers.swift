// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXNN

/// A dense block with dilated convolutions and residual connections.
class DenseBlock: Module, UnaryLayer {
    let layers: [Sequential]

    init(hidFeature: Int, depth: Int = 4) {
        self.layers = (0..<depth).map { i in
            let dilation = Int(pow(2.0, Double(i)))
            return Sequential(layers: [
                Conv2d(inputChannels: hidFeature * (i + 1),
                       outputChannels: hidFeature,
                       kernelSize: IntOrPair((3, 3)),
                       padding: IntOrPair((dilation, 1)),
                       dilation: IntOrPair((dilation, 1))),
                InstanceNorm(dimensions: hidFeature, affine: true),
                PReLU()
            ])
        }
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var skip = x
        var current = x
        let lastIdx = layers.count - 1
        for (i, layer) in layers.enumerated() {
            current = layer(skip)
            // Materialize before concatenation so the lazy graph does not retain
            // every DenseBlock intermediate until the enclosing model evaluation.
            MLX.eval(current)
            // Only accumulate `skip` if a subsequent layer will consume it.
            if i < lastIdx {
                skip = MLX.concatenated([current, skip], axis: -1)
                // Materialize so the previous skip can be freed before the next
                // layer allocates instead of remaining live through final eval.
                MLX.eval(skip)
            }
        }
        return current
    }
}

/// Encoder that compresses spectral features.
class DenseEncoder: Module, UnaryLayer {
    let conv1: Sequential
    let denseBlock: DenseBlock
    let conv2: Sequential
    
    init(inputChannel: Int = 2, hidFeature: Int = 64) {
        self.conv1 = Sequential(layers: [
            Conv2d(inputChannels: inputChannel, outputChannels: hidFeature, kernelSize: IntOrPair(1)),
            InstanceNorm(dimensions: hidFeature, affine: true),
            PReLU()
        ])
        self.denseBlock = DenseBlock(hidFeature: hidFeature, depth: 4)
        self.conv2 = Sequential(layers: [
            Conv2d(inputChannels: hidFeature, outputChannels: hidFeature, kernelSize: IntOrPair((1, 3)), stride: IntOrPair((4, 2))),
            InstanceNorm(dimensions: hidFeature, affine: true),
            PReLU()
        ])
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        var x = conv1(x)
        x = denseBlock(x)
        x = conv2(x)
        return x
    }
}

/// Sub-pixel convolution for 2D upsampling.
class SPConvTranspose2d: Module, UnaryLayer {
    let conv: Conv2d
    let r: Int
    
    init(inChannels: Int, outChannels: Int, kernelSize: IntOrPair, r: Int) {
        self.conv = Conv2d(inputChannels: inChannels, outputChannels: outChannels * r, kernelSize: kernelSize, stride: IntOrPair(1))
        self.r = r
        super.init()
    }
    
    func callAsFunction(_ x: MLXArray) -> MLXArray {
        // x: [B, H, W, C]
        // ConstantPad2d((1, 1, 0, 0)) -> pads W axis.
        let pad = MLX.padded(x, widths: [IntOrPair(0), IntOrPair(0), IntOrPair((1, 1)), IntOrPair(0)])
        var out = conv(pad)

        // out: [B, H, W, outChannels * r]
        // PyTorch reference (NCHW):
        //   view(B, r, C, H, W) -> permute(0, 2, 3, 4, 1) -> view(B, C, H, W*r)
        // i.e. the Cr dim splits as (r outer, C inner), then r is interleaved
        // into W as the fast-varying axis so the final W*r index = w*r + ρ.
        //
        // In MLX NHWC the equivalent is: reshape Cr as (r, C) with r outer,
        // then merge (W, r) into a single W*r axis via a second reshape.
        let (b, h, w, c_r) = (out.shape[0], out.shape[1], out.shape[2], out.shape[3])
        let outChannels = c_r / r
        out = out.reshaped(b, h, w, r, outChannels)
        out = out.reshaped(b, h, w * r, outChannels)
        return out
    }
}

/// Shared upsampling trunk used by both MagDecoder and PhaseDecoder.
fileprivate func decoderTrunk(_ x: MLXArray,
                              _ denseBlock: DenseBlock,
                              _ upConv1: Sequential,
                              _ upConv2: Sequential) -> MLXArray {
    var x = denseBlock(x)
    x = upConv1(x)
    // Python: x = upConv2(x.permute(0, 1, 3, 2)).permute(0, 1, 3, 2)
    // In PyTorch NCHW this swaps H and W. In MLX NHWC, H is axis 1 and W is axis 2,
    // so we transpose axes 1 and 2 (keeping batch and channel fixed).
    x = x.transposed(0, 2, 1, 3)
    x = upConv2(x)
    x = x.transposed(0, 2, 1, 3)
    return x
}

/// Decoder that reconstructs the magnitude mask.
class MagDecoder: Module, UnaryLayer {
    let denseBlock: DenseBlock
    let upConv1: Sequential
    let upConv2: Sequential
    let finalConv: Conv2d

    init(hidFeature: Int = 64, outputChannel: Int = 1) {
        self.denseBlock = DenseBlock(hidFeature: hidFeature, depth: 4)
        self.upConv1 = Sequential(layers: [
            SPConvTranspose2d(inChannels: hidFeature, outChannels: hidFeature, kernelSize: IntOrPair((1, 3)), r: 2),
            InstanceNorm(dimensions: hidFeature, affine: true),
            PReLU()
        ])
        self.upConv2 = Sequential(layers: [
            SPConvTranspose2d(inChannels: hidFeature, outChannels: hidFeature, kernelSize: IntOrPair((1, 3)), r: 4),
            InstanceNorm(dimensions: hidFeature, affine: true),
            PReLU()
        ])
        self.finalConv = Conv2d(inputChannels: hidFeature, outputChannels: outputChannel, kernelSize: IntOrPair(1))
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = decoderTrunk(x, denseBlock, upConv1, upConv2)
        return finalConv(h)
    }
}

/// Decoder that reconstructs the phase mask via atan2(imag, real).
class PhaseDecoder: Module, UnaryLayer {
    let denseBlock: DenseBlock
    let upConv1: Sequential
    let upConv2: Sequential
    let phaseConvR: Conv2d
    let phaseConvI: Conv2d

    init(hidFeature: Int = 64, outputChannel: Int = 1) {
        self.denseBlock = DenseBlock(hidFeature: hidFeature, depth: 4)
        self.upConv1 = Sequential(layers: [
            SPConvTranspose2d(inChannels: hidFeature, outChannels: hidFeature, kernelSize: IntOrPair((1, 3)), r: 2),
            InstanceNorm(dimensions: hidFeature, affine: true),
            PReLU()
        ])
        self.upConv2 = Sequential(layers: [
            SPConvTranspose2d(inChannels: hidFeature, outChannels: hidFeature, kernelSize: IntOrPair((1, 3)), r: 4),
            InstanceNorm(dimensions: hidFeature, affine: true),
            PReLU()
        ])
        self.phaseConvR = Conv2d(inputChannels: hidFeature, outputChannels: outputChannel, kernelSize: IntOrPair(1))
        self.phaseConvI = Conv2d(inputChannels: hidFeature, outputChannels: outputChannel, kernelSize: IntOrPair(1))
        super.init()
    }

    func callAsFunction(_ x: MLXArray) -> MLXArray {
        let h = decoderTrunk(x, denseBlock, upConv1, upConv2)
        let xR = phaseConvR(h)
        let xI = phaseConvI(h)
        return MLX.atan2(xI, xR)
    }
}
