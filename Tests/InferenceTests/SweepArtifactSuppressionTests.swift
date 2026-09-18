// SPDX-License-Identifier: Apache-2.0

import MLX
import XCTest
@testable import Inference

final class SweepArtifactSuppressionTests: XCTestCase {
    func testSuppressesOnlyFramesWithStrictMajorityOfZeroFrequencyBins() {
        let magnitude = MLXArray([
            // Batch 0: frame 0 has 3/5 zeros; frame 1 has exactly 2/5.
            0, 0,
            0, 2,
            0, 0,
            4, 4,
            5, 3,
            // Batch 1 verifies suppression is independent per batch item.
            1, 0,
            2, 0,
            3, 0,
            4, 4,
            5, 5,
        ] as [Float], [2, 5, 2])

        let result = suppressSweepArtifactFrames(magnitude)
        MLX.eval(result)

        XCTAssertEqual(result.shape, [2, 5, 2])
        XCTAssertEqual(result.asArray(Float.self), [
            0, 0,
            0, 2,
            0, 0,
            0, 4,
            0, 3,
            1, 0,
            2, 0,
            3, 0,
            4, 0,
            5, 0,
        ])
    }
}
