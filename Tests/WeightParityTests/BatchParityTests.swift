// SPDX-License-Identifier: Apache-2.0

import XCTest
import MLX
import MLXNN
@testable import Inference
import TestSupport

/// Verifies that internal `SEMamba` supports independent batch elements and
/// that one B=2 execution is numerically equivalent to two B=1 executions.
///
/// `MambaEnhancer` processes one mono model window at a time. Keeping this
/// internal capability tested preserves the option to batch equal-shaped
/// windows later when it provides a measured throughput benefit.
///
/// Runs on the default device (GPU on Apple Silicon) because that's where
/// the production path runs and where Metal scan kernels could differ from
/// CPU. Uses the time-reversed input as the second batch element to ensure
/// the two elements are meaningfully different (trivially equal inputs
/// would mask cross-talk bugs).
final class BatchParityTests: XCTestCase {
    // Looser than WeightParityTests's 1e-3 reference tolerance: here we're
    // comparing two runs of the same code on the same device, so the only
    // drift source is op-ordering differences between B=1 and B=2 dispatch.
    private let magTolerance: Float = 5e-5
    // Phase passes through atan2, which amplifies small component differences.
    private let phaTolerance: Float = 5e-4

    func testBatchTwoMatchesSerialPair() throws {
        defer {
            // mlx-swift 0.31.3 can reuse B=2 cached buffers incorrectly in
            // the first later B=1 graph. Keep this test-only workload from
            // contaminating the production-shaped suites in this process.
            Stream.gpu.synchronize()
            MLX.Memory.clearCache()
        }
        let modelURL: URL
        do {
            modelURL = try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }
        let probesURL = ModelTestPaths.projectRoot
            .appendingPathComponent("Tests/Fixtures/Reference/parity_probes.safetensors")

        XCTAssertTrue(FileManager.default.fileExists(atPath: probesURL.path), "Parity probes missing")

        let model = SEMamba(numBlocks: 30)
        let modelWeights = try MLX.loadArrays(url: modelURL)
        model.update(parameters: ModuleParameters.unflattened(modelWeights))

        let probes = try MLX.loadArrays(url: probesURL)
        let inputMagA = try XCTUnwrap(probes["input_mag"])  // [1, F, T]
        let inputPhaA = try XCTUnwrap(probes["input_pha"])  // [1, F, T]

        // Build a genuinely different second batch element by time-reversing
        // the probe's input. Axis 2 is the T axis in [B, F, T].
        let inputMagB = inputMagA[0..., 0..., .stride(by: -1)]
        let inputPhaB = inputPhaA[0..., 0..., .stride(by: -1)]

        let (serialMagA, serialPhaA) = model(inputMagA, inputPhaA)
        let (serialMagB, serialPhaB) = model(inputMagB, inputPhaB)
        MLX.eval(serialMagA, serialPhaA, serialMagB, serialPhaB)

        let batchMag = MLX.concatenated([inputMagA, inputMagB], axis: 0)
        let batchPha = MLX.concatenated([inputPhaA, inputPhaB], axis: 0)
        let (batchedMag, batchedPha) = model(batchMag, batchPha)
        MLX.eval(batchedMag, batchedPha)

        let batchedMag0 = batchedMag[0..<1, 0..., 0...]
        let batchedMag1 = batchedMag[1..<2, 0..., 0...]
        let batchedPha0 = batchedPha[0..<1, 0..., 0...]
        let batchedPha1 = batchedPha[1..<2, 0..., 0...]

        assertClose(batchedMag0, serialMagA, tol: magTolerance, name: "mag[0] vs serial(A)")
        assertClose(batchedMag1, serialMagB, tol: magTolerance, name: "mag[1] vs serial(B)")
        assertClose(batchedPha0, serialPhaA, tol: phaTolerance, name: "pha[0] vs serial(A)")
        assertClose(batchedPha1, serialPhaB, tol: phaTolerance, name: "pha[1] vs serial(B)")
    }

    private func assertClose(_ a: MLXArray, _ b: MLXArray, tol: Float, name: String) {
        let diff = (a - b).abs().max().item(Float.self)
        print("BatchParity [\(name)]: Max diff = \(diff)")
        XCTAssertLessThan(diff, tol, "[\(name)] batch-vs-serial diff \(diff) > \(tol)")
    }
}
