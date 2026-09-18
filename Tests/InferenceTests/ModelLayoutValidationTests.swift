// SPDX-License-Identifier: Apache-2.0

import XCTest
import MLX
@testable import Inference

final class ModelLayoutValidationTests: XCTestCase {
    func testRejectsNon16MambaStateBeforeWeightMapping() {
        var weights = weightsWithAllBlockIndices()
        weights["tfMamba.0.timeMamba.forward.A_log"] = MLX.zeros([256, 17])

        XCTAssertThrowsError(try MambaEnhancer.validateModelWeights(weights)) { error in
            guard case InferenceError.metalInferenceIncompatible(let message) = error else {
                return XCTFail("Expected Metal compatibility error, got \(error)")
            }
            XCTAssertTrue(message.contains("fixed-16"))
        }
    }

    func testRejectsCheckpointMissingRequiredMambaTensor() {
        var weights = weightsWithAllBlockIndices()
        weights.removeValue(forKey: "tfMamba.0.timeMamba.forward.D")

        XCTAssertThrowsError(try MambaEnhancer.validateModelWeights(weights)) { error in
            guard case InferenceError.unsupportedModelArchitecture(let message) = error else {
                return XCTFail("Expected unsupported architecture error, got \(error)")
            }
            XCTAssertTrue(message.contains("missing required tensor"))
        }
    }

    func testRejectsCheckpointWithUnsupportedBlockCount() {
        let weights = [
            "tfMamba.30.timeMamba.forward.A_log": MLX.zeros([256, reUseMambaStateSize])
        ]

        XCTAssertThrowsError(try MambaEnhancer.validateModelWeights(weights)) { error in
            guard case InferenceError.unsupportedModelArchitecture(let message) = error else {
                return XCTFail("Expected unsupported architecture error, got \(error)")
            }
            XCTAssertTrue(message.contains("exactly 30 TFMamba blocks"))
        }
    }

    private func weightsWithAllBlockIndices() -> [String: MLXArray] {
        let branches = ["timeMamba.forward", "timeMamba.backward", "freqMamba.forward", "freqMamba.backward"]
        var weights = [String: MLXArray]()
        for index in 0..<30 {
            for branch in branches {
                let prefix = "tfMamba.\(index).\(branch)"
                weights["\(prefix).A_log"] = MLX.zeros([256, reUseMambaStateSize])
                weights["\(prefix).D"] = MLX.zeros([256])
                weights["\(prefix).xProj.weight"] = MLX.zeros([36, 256])
                weights["\(prefix).dtProj.weight"] = MLX.zeros([256, 4])
            }
        }
        return weights
    }
}
