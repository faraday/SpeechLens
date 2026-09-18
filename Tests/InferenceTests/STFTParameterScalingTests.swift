// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Inference

final class STFTParameterScalingTests: XCTestCase {
    func testNativeRateParametersMirrorNVIDIAIntegerScaling() {
        assertParameters(sampleRate: 16_000, nFFT: 640, hop: 80, win: 640)
        assertParameters(sampleRate: 44_100, nFFT: 1_764, hop: 220, win: 1_764)
        assertParameters(sampleRate: 48_000, nFFT: 1_920, hop: 240, win: 1_920)
    }

    func testIntegerDivisionPrecedesEvenRoundingAtHalfSampleBoundary() {
        XCTAssertEqual(
            MambaEnhancer.nvidiaScaledEvenParameter(base: 40, sampleRate: 44_100),
            220
        )
    }

    func testHannWindowMatchesPyTorchPeriodicDefinition() {
        let actual = MambaEnhancer.nvidiaPeriodicHannWindow(8)
        let expected: [Float] = [
            0.0, 0.14644662, 0.5, 0.8535534,
            1.0, 0.8535534, 0.5, 0.14644662,
        ]

        XCTAssertEqual(actual.count, expected.count)
        for (actualValue, expectedValue) in zip(actual, expected) {
            XCTAssertEqual(actualValue, expectedValue, accuracy: 1e-6)
        }
        XCTAssertGreaterThan(actual[actual.count - 1], 0.0,
            "Periodic Hann must not force the final sample to zero.")
    }

    private func assertParameters(sampleRate: Int, nFFT: Int, hop: Int, win: Int) {
        let actual = MambaEnhancer.scaledSTFTParams(sampleRate: sampleRate)
        XCTAssertEqual(actual.nFFT, nFFT, "sampleRate=\(sampleRate)")
        XCTAssertEqual(actual.hop, hop, "sampleRate=\(sampleRate)")
        XCTAssertEqual(actual.win, win, "sampleRate=\(sampleRate)")
    }
}
