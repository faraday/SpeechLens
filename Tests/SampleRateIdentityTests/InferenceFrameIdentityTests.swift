// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import Inference
import AudioIO
import TestSupport

final class InferenceFrameIdentityTests: XCTestCase {
    func testInferencePreservesFrameCountAt16000Hz() async throws {
        try await assertInferenceFrameIdentity(sampleRate: 16_000)
    }

    func testInferencePreservesFrameCountAt44100Hz() async throws {
        try await assertInferenceFrameIdentity(sampleRate: 44_100)
    }

    func testInferencePreservesFrameCountAt48000Hz() async throws {
        try await assertInferenceFrameIdentity(sampleRate: 48_000)
    }

    private func assertInferenceFrameIdentity(sampleRate: Int) async throws {
        let frameCount = sampleRate
        var samples = [Float](repeating: 0, count: frameCount)
        let frequency: Float = 440.0
        let twoPi = Float.pi * 2.0
        for i in 0..<frameCount {
            samples[i] = sinf(twoPi * frequency * Float(i) / Float(sampleRate))
        }

        let weightsURL: URL
        do {
            weightsURL = try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        let enhancer = try MambaEnhancer(modelWeightsURL: weightsURL)
        let output = try await collectEnhancedSamples(
            enhancer: enhancer,
            samples: samples,
            sampleRate: sampleRate,
            settings: .standard
        )

        XCTAssertEqual(output.count, samples.count)
        XCTAssertTrue(output.allSatisfy(\.isFinite))
    }
}
