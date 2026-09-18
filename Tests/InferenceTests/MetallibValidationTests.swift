// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Inference

final class MetallibValidationTests: XCTestCase {
    private func makeTemporaryBinaryDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechlens-metallib-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func writeMetallib(_ url: URL, compatible: Bool) throws {
        let text = compatible ? "prefix layer_normfloat32 suffix" : "not compatible"
        try Data(text.utf8).write(to: url)
    }

    func testAcceptsCompatibleColocatedMetallib() throws {
        let dir = try makeTemporaryBinaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("SpeechLens")
        let metallib = dir.appendingPathComponent("mlx.metallib")
        try Data().write(to: binary)
        try writeMetallib(metallib, compatible: true)

        let resolved = try MambaEnhancer.validatePackagedMLXMetallib(executableURL: binary, environment: [:])
        XCTAssertEqual(resolved.path, metallib.path)
    }

    func testAcceptsCompatibleResourcesMetallib() throws {
        let dir = try makeTemporaryBinaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("SpeechLens")
        let resources = dir.appendingPathComponent("Resources", isDirectory: true)
        let metallib = resources.appendingPathComponent("mlx.metallib")
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try Data().write(to: binary)
        try writeMetallib(metallib, compatible: true)

        let resolved = try MambaEnhancer.validatePackagedMLXMetallib(executableURL: binary, environment: [:])
        XCTAssertEqual(resolved.path, metallib.path)
    }

    func testRejectsIncompatiblePackagedMetallib() throws {
        let dir = try makeTemporaryBinaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("SpeechLens")
        let metallib = dir.appendingPathComponent("mlx.metallib")
        try Data().write(to: binary)
        try writeMetallib(metallib, compatible: false)

        XCTAssertThrowsError(try MambaEnhancer.validatePackagedMLXMetallib(executableURL: binary, environment: [:])) { error in
            let message = (error as? InferenceError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("incompatible"), message)
            XCTAssertTrue(message.contains(metallib.path), message)
        }
    }

    func testMissingMetallibDiagnosticMentionsRuntimeDoesNotCopyOverride() throws {
        let dir = try makeTemporaryBinaryDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        let binary = dir.appendingPathComponent("SpeechLens")
        try Data().write(to: binary)

        XCTAssertThrowsError(
            try MambaEnhancer.validatePackagedMLXMetallib(
                executableURL: binary,
                environment: ["MLX_METALLIB_PATH": "/tmp/mlx.metallib"]
            )
        ) { error in
            let message = (error as? InferenceError)?.errorDescription ?? String(describing: error)
            XCTAssertTrue(message.contains("not packaged"), message)
            XCTAssertTrue(message.contains("runtime does not copy or compile"), message)
            XCTAssertTrue(message.contains("MLX_METALLIB_PATH"), message)
        }
    }
}
