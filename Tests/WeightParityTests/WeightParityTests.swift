// SPDX-License-Identifier: Apache-2.0

import XCTest
import MLX
import MLXNN
@testable import Inference
import TestSupport

final class WeightParityTests: XCTestCase {
    private let baseTolerance: Float = 1e-3
    // Phase is produced via atan2(imag, real) and the model uses GPU-only custom
    // Metal kernels, making it more sensitive than magnitude to runtime drift.
    private let phaseTolerance: Float = 1.3e-3
    
    override func setUp() {
        super.setUp()
    }
    
    func testModelParity() throws {
        let modelURL: URL
        do {
            modelURL = try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        try Device.withDefaultDevice(Device.gpu) {
            let probesURL = ModelTestPaths.projectRoot
                .appendingPathComponent("Tests/Fixtures/Reference/parity_probes.safetensors")
            
            XCTAssertTrue(FileManager.default.fileExists(atPath: probesURL.path), "Parity probes missing")
            
            let model = SEMamba(numBlocks: 30)
            let modelWeights = try MLX.loadArrays(url: modelURL)
            model.update(parameters: ModuleParameters.unflattened(modelWeights))
            
            let probes = try MLX.loadArrays(url: probesURL)
            
            let inputMag = try XCTUnwrap(probes["input_mag"])
            let inputPha = try XCTUnwrap(probes["input_pha"])
            let (_, f, t) = (inputMag.shape[0], inputMag.shape[1], inputMag.shape[2])
            
            let refEncoderOut = try XCTUnwrap(probes["encoder_out"]).transposed(0, 2, 3, 1)
            let refBlock0Out = try XCTUnwrap(probes["block_0_out"]).transposed(0, 2, 3, 1)
            let refFinalMask = try XCTUnwrap(probes["final_mask"])
            
            let magT = inputMag.transposed(0, 2, 1)
            let phaT = inputPha.transposed(0, 2, 1)
            let x = MLX.stacked([magT, phaT], axis: -1)
            
            let xP = MLX.padded(x, widths: [IntOrPair(0), IntOrPair((0, 2)), IntOrPair((0, 2)), IntOrPair(0)])
            
            let encoderOut = model.denseEncoder(xP)
            assertEqual(encoderOut, refEncoderOut, tol: baseTolerance, name: "DenseEncoder")
            
            var currentX = encoderOut
            for i in 0..<30 {
                currentX = model.tfMamba[i](currentX)
                if i == 0 {
                    assertEqual(currentX, refBlock0Out, tol: baseTolerance, name: "Block 0")
                }
            }
            
            let denoisedMag = model.maskDecoder(currentX)
            let denoisedPha = model.phaseDecoder(currentX)
            
            // Remove model padding and restore the reference `[B, F, T]` layout.
            let maskMag = denoisedMag[0..., ..<t, ..<f, 0].transposed(0, 2, 1)
            let maskPha = denoisedPha[0..., ..<t, ..<f, 0].transposed(0, 2, 1)
            
            assertEqual(maskMag, refFinalMask, tol: baseTolerance, name: "Final Mask (Mag)")
            if let refPhase = probes["final_phase"] {
                assertEqual(maskPha, refPhase, tol: phaseTolerance, name: "Final Mask (Phase)")
            }
        }
    }
    
    private func assertEqual(_ a: MLXArray, _ b: MLXArray, tol: Float, name: String) {
        let diff = (a - b).abs().max().item(Float.self)
        print("Parity [\(name)]: Max diff = \(diff)")
        XCTAssertLessThan(diff, tol, "[\(name)] Parity failure: diff \(diff) > \(tol)")
    }
}
