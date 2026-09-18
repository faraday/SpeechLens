// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import Inference
import ArgumentParser

@main
struct WeightPort: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "WeightPort",
        abstract: "Convert upstream RE-USE Safetensors weights for SpeechLens MLX."
    )

    @Option(
        name: .long,
        help: "Path to upstream model.safetensors. Defaults to SPEECHLENS_SOURCE_WEIGHTS."
    )
    var input: String?

    @Option(
        name: .long,
        help: "Destination for converted MLX weights."
    )
    var output = "Models/model_mlx.safetensors"

    mutating func run() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard let inputPath = input ?? environment["SPEECHLENS_SOURCE_WEIGHTS"],
              !inputPath.isEmpty else {
            throw ValidationError(
                "Provide --input <model.safetensors> or set SPEECHLENS_SOURCE_WEIGHTS."
            )
        }

        let originalURL = URL(fileURLWithPath: inputPath).standardizedFileURL
        let outputURL = URL(fileURLWithPath: output).standardizedFileURL
        guard FileManager.default.fileExists(atPath: originalURL.path) else {
            throw ValidationError("Source weights not found at \(originalURL.path)")
        }

        try FileManager.default.createDirectory(
            at: outputURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        print("WeightPort: Loading original weights from \(originalURL.path)...")
        let weights = try MLX.loadArrays(url: originalURL)

        var mapped: [String: MLXArray] = [:]

        for (key, tensor) in weights {
            let newKey = Self.mapKey(key)
            var newTensor = tensor

            // Handle depthwise conv1d weights: PyTorch [C, 1, K] -> MLX [C, K, 1]
            if key.contains("conv1d") && key.hasSuffix("weight") && tensor.ndim == 3 {
                newTensor = tensor.transposed(0, 2, 1)
            } else if key.hasSuffix("weight") && tensor.ndim == 4 {
                // All 4D weights in this model are Conv2d: PyTorch [O, I, H, W] -> MLX [O, H, W, I].
                // Can't rely on a "conv" substring in the key — e.g. dense_block.*.weight carries no
                // "conv" token even though the underlying module is a Conv2d.
                newTensor = tensor.transposed(0, 2, 3, 1)
            } else if key.contains("dt_proj") && key.hasSuffix("bias") {
                newTensor = tensor.asType(DType.float32)
            }

            mapped[newKey] = newTensor
        }

        print("WeightPort: \(mapped.count) tensors mapped.")
        print("WeightPort: Saving to \(outputURL.path)...")
        try MLX.save(arrays: mapped, url: outputURL)
        print("WeightPort: Success!")
    }

    /// Maps original PyTorch weight keys to the MLX Swift model structure.
    static func mapKey(_ key: String) -> String {
        var k = key

        // Upstream checkpoints may include one optional wrapper component.
        if k.hasPrefix("model.") { k.removeFirst(6) }

        // Expand nested DenseBlock Sequentials before top-level renames so this
        // still sees the raw "dense_block.dense_block.i.j." pattern.
        for i in 0..<10 {
            for j in 0..<10 {
                k = k.replacingOccurrences(
                    of: "dense_block.dense_block.\(i).\(j).",
                    with: "denseBlock.layers.\(i).layers.\(j).")
            }
        }

        // Convert upstream module names to their Swift property names.
        let simpleRenames: [(String, String)] = [
            ("dense_encoder.", "denseEncoder."),
            ("mask_decoder.", "maskDecoder."),
            ("phase_decoder.", "phaseDecoder."),
            ("TSMamba.", "tfMamba."),
            ("time_mamba.", "timeMamba."),
            ("freq_mamba.", "freqMamba."),
            ("forward_blocks.", "forward."),
            ("backward_blocks.", "backward."),
            ("output_proj.", "outputProj."),
            ("in_proj.", "inProj."),
            ("out_proj.", "outProj."),
            ("x_proj.", "xProj."),
            ("dt_proj.", "dtProj."),
            ("final_conv.", "finalConv."),
            ("phase_conv_r.", "phaseConvR."),
            ("phase_conv_i.", "phaseConvI."),
        ]
        for (old, new) in simpleRenames {
            k = k.replacingOccurrences(of: old, with: new)
        }

        // Expand indices for the four remaining Sequential containers.
        let seqParents = ["dense_conv_1", "dense_conv_2", "up_conv1", "up_conv2"]
        let seqTargets = ["conv1",        "conv2",        "upConv1",  "upConv2"]
        for (parent, target) in zip(seqParents, seqTargets) {
            for i in 0..<10 {
                k = k.replacingOccurrences(
                    of: "\(parent).\(i).",
                    with: "\(target).layers.\(i).")
            }
        }

        return k
    }
}
