// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX
import MLXNN
import TestSupport
import XCTest
@testable import Inference

final class MLXCacheIsolationTests: XCTestCase {
    private static let reproduceEnvironmentKey = "SPEECHLENS_REPRODUCE_MLX_CACHE_BUG"
    private static let cpuControlEnvironmentKey = "SPEECHLENS_MLX_CACHE_CPU_CONTROL"
    private static let freshStreamControlEnvironmentKey = "SPEECHLENS_MLX_CACHE_FRESH_STREAM"

    func testBatchWarmupCacheIsClearedBeforeSerialInference() async throws {
        if ProcessInfo.processInfo.environment[Self.cpuControlEnvironmentKey] == "1" {
            try await Device.withDefaultDevice(Device.cpu) {
                try await runCacheIsolationScenario()
            }
        } else {
            try await runCacheIsolationScenario()
        }
    }

    private func runCacheIsolationScenario() async throws {
        let weightsURL: URL
        do {
            weightsURL = try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        try performBatchWarmup(weightsURL: weightsURL)
        defer { MLX.Memory.clearCache() }
        if ProcessInfo.processInfo.environment[Self.reproduceEnvironmentKey] != "1" {
            MLX.Memory.clearCache()
        }

        let maximumDifference: Float
        if ProcessInfo.processInfo.environment[Self.freshStreamControlEnvironmentKey] == "1" {
            maximumDifference = try await Stream.withNewDefaultStream {
                try await compareRepeatedWindows(weightsURL: weightsURL)
            }
        } else {
            maximumDifference = try await compareRepeatedWindows(weightsURL: weightsURL)
        }

        XCTAssertLessThanOrEqual(
            maximumDifference,
            1e-5,
            "B=2 cache state changed the next repeated B=1 window"
        )
    }

    private func compareRepeatedWindows(weightsURL: URL) async throws -> Float {
        let sampleRate = 44_100
        let samples = speechLikeSignal(sampleRate: sampleRate, frameCount: sampleRate)
        let enhancer = try MambaEnhancer(modelWeightsURL: weightsURL)
        let first = try await enhancer.enhanceWindow(samples, sampleRate: sampleRate)
        let second = try await enhancer.enhanceWindow(samples, sampleRate: sampleRate)
        return zip(first, second).map { abs($0 - $1) }.max() ?? 0
    }

    private func performBatchWarmup(weightsURL: URL) throws {
        let probesURL = ModelTestPaths.projectRoot
            .appendingPathComponent("Tests/Fixtures/Reference/parity_probes.safetensors")
        let probes = try MLX.loadArrays(url: probesURL)
        let inputMag = try XCTUnwrap(probes["input_mag"])
        let inputPha = try XCTUnwrap(probes["input_pha"])
        let reversedMag = inputMag[0..., 0..., .stride(by: -1)]
        let reversedPha = inputPha[0..., 0..., .stride(by: -1)]
        let model = SEMamba(numBlocks: 30)
        let weights = try MLX.loadArrays(url: weightsURL)
        model.update(parameters: ModuleParameters.unflattened(weights))
        let batchMag = MLX.concatenated([inputMag, reversedMag], axis: 0)
        let batchPha = MLX.concatenated([inputPha, reversedPha], axis: 0)
        let (outputMag, outputPha) = model(batchMag, batchPha)
        MLX.eval(outputMag, outputPha)
        StreamOrDevice.default.stream.synchronize()
    }

    private func speechLikeSignal(sampleRate: Int, frameCount: Int) -> [Float] {
        (0..<frameCount).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = 0.55 + 0.45 * sin(2 * Double.pi * 3 * time)
            let sample = sin(2 * Double.pi * 310 * time)
                + 0.35 * sin(2 * Double.pi * 870 * time)
            return Float(0.08 * envelope * sample)
        }
    }
}
