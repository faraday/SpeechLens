// SPDX-License-Identifier: Apache-2.0

import XCTest
import MLX
@testable import Inference

final class SelectiveScanParityTests: XCTestCase {
    func testFixedScanIsDeterministicForBatchOneAndTwo() throws {
        for batch in [1, 2] {
            let inputs = makeScanInputs(batch: batch, length: 128, channels: 256)
            let first = try runScan(inputs)
            let second = try runScan(inputs)
            assertExactlyEqual(first, second, label: "fixed16 B=\(batch) repeat")
        }
    }

    func testFixedScanRejectsNon16State() {
        for state in [15, 17] {
            let inputs = makeScanInputs(batch: 1, length: 8, channels: 16, state: state)
            XCTAssertThrowsError(try validateScan(inputs), "N=\(state) should be rejected")
        }
    }

    func testFixedScanRejectsInconsistentSequenceShape() {
        let inputs = makeScanInputs(batch: 1, length: 8, channels: 16)
        let malformedB = MLX.zeros([1, 7, reUseMambaStateSize])
        XCTAssertThrowsError(
            try MetalSelectiveScan.validateInputShapes(
                deltaRaw: inputs.deltaRaw,
                A_log: inputs.aLog,
                B: malformedB,
                C: inputs.c,
                u: inputs.u,
                D: inputs.d,
                z: inputs.z
            )
        )
    }

    func testStrictScanIsDeterministicForBatchOneAndTwo() throws {
        for batch in [1, 2] {
            let inputs = makeScanInputs(batch: batch, length: 128, channels: 256)
            let first = try runScan(inputs, mode: .strict)
            let second = try runScan(inputs, mode: .strict)
            assertExactlyEqual(first, second, label: "strict B=\(batch) repeat")
        }
    }

    func testStrictScanRemainsFiniteForSoftplusAndDecayExtremes() throws {
        let batch = 1
        let length = 8
        let channels = 16
        let state = reUseMambaStateSize
        let inputs: ScanInputs = (
            MLXArray([Float](repeating: 1000, count: batch * length * channels), [batch, length, channels]),
            MLXArray([Float](repeating: 0, count: channels * state), [channels, state]),
            MLXArray([Float](repeating: 0, count: batch * length * state), [batch, length, state]),
            MLXArray([Float](repeating: 0, count: batch * length * state), [batch, length, state]),
            MLXArray([Float](repeating: 1, count: batch * length * channels), [batch, length, channels]),
            MLXArray([Float](repeating: 0, count: channels), [channels]),
            MLXArray([Float](repeating: 0, count: batch * length * channels), [batch, length, channels])
        )

        let output = try runScan(inputs, mode: .strict)
        XCTAssertTrue(output.asArray(Float.self).allSatisfy(\.isFinite))
    }

    private typealias ScanInputs = (
        deltaRaw: MLXArray,
        aLog: MLXArray,
        b: MLXArray,
        c: MLXArray,
        u: MLXArray,
        d: MLXArray,
        z: MLXArray
    )

    private func makeScanInputs(
        batch: Int,
        length: Int,
        channels: Int,
        state: Int = reUseMambaStateSize
    ) -> ScanInputs {
        func values(_ count: Int, scale: Float) -> [Float] {
            (0..<count).map { Float(($0 * 37) % 251 - 125) * scale }
        }
        return (
            MLXArray(values(batch * length * channels, scale: 0.003), [batch, length, channels]),
            MLXArray(values(channels * state, scale: 0.002), [channels, state]),
            MLXArray(values(batch * length * state, scale: 0.004), [batch, length, state]),
            MLXArray(values(batch * length * state, scale: 0.005), [batch, length, state]),
            MLXArray(values(batch * length * channels, scale: 0.006), [batch, length, channels]),
            MLXArray(values(channels, scale: 0.007), [channels]),
            MLXArray(values(batch * length * channels, scale: 0.008), [batch, length, channels])
        )
    }

    private func runScan(
        _ inputs: ScanInputs,
        mode: InferenceMode = .standard
    ) throws -> MLXArray {
        try validateScan(inputs)
        let output = MetalSelectiveScan.run(
            deltaRaw: inputs.deltaRaw,
            A_log: inputs.aLog,
            B: inputs.b,
            C: inputs.c,
            u: inputs.u,
            D: inputs.d,
            z: inputs.z,
            mode: mode
        )
        MLX.eval(output)
        return output
    }

    private func validateScan(_ inputs: ScanInputs) throws {
        try MetalSelectiveScan.validateInputShapes(
            deltaRaw: inputs.deltaRaw,
            A_log: inputs.aLog,
            B: inputs.b,
            C: inputs.c,
            u: inputs.u,
            D: inputs.d,
            z: inputs.z
        )
    }

    private func assertExactlyEqual(_ lhs: MLXArray, _ rhs: MLXArray, label: String) {
        let difference = (lhs - rhs).abs().max().item(Float.self)
        XCTAssertEqual(difference, 0, "\(label) max absolute difference: \(difference)")
    }
}
