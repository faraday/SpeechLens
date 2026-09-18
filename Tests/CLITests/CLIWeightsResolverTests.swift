// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import CLI

final class CLIWeightsResolverTests: XCTestCase {
    private let cwd = URL(fileURLWithPath: "/tmp/speechlens-cli-cwd", isDirectory: true)
    private let appSupport = URL(fileURLWithPath: "/tmp/speechlens-cli-app-support", isDirectory: true)

    func testExplicitWeightsPathWinsWhenPresent() throws {
        let explicit = cwd.appendingPathComponent("custom.safetensors")
        let appCache = appSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors")

        let resolved = try CLIWeightsResolver.resolve(
            explicitPath: "custom.safetensors",
            environment: [CLIWeightsResolver.environmentKey: "/ignored/env.safetensors"],
            currentDirectoryURL: cwd,
            applicationSupportURL: appSupport,
            fileExists: existing([explicit.path, appCache.path])
        )

        XCTAssertEqual(resolved.path, explicit.path)
    }

    func testEnvironmentPathWinsOverAppCacheAndCurrentDirectory() throws {
        let envURL = URL(fileURLWithPath: "/models/env.safetensors")
        let appCache = appSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors")
        let local = cwd.appendingPathComponent("model_mlx.safetensors")

        let resolved = try CLIWeightsResolver.resolve(
            explicitPath: nil,
            environment: [CLIWeightsResolver.environmentKey: envURL.path],
            currentDirectoryURL: cwd,
            applicationSupportURL: appSupport,
            fileExists: existing([envURL.path, appCache.path, local.path])
        )

        XCTAssertEqual(resolved.path, envURL.path)
    }

    func testAppCacheWinsOverCurrentDirectoryFallback() throws {
        let appCache = appSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors")
        let local = cwd.appendingPathComponent("model_mlx.safetensors")

        let resolved = try CLIWeightsResolver.resolve(
            explicitPath: nil,
            environment: [:],
            currentDirectoryURL: cwd,
            applicationSupportURL: appSupport,
            fileExists: existing([appCache.path, local.path])
        )

        XCTAssertEqual(resolved.path, appCache.path)
    }

    func testCurrentDirectoryFallbackIsUsedLast() throws {
        let local = cwd.appendingPathComponent("model_mlx.safetensors")

        let resolved = try CLIWeightsResolver.resolve(
            explicitPath: nil,
            environment: [:],
            currentDirectoryURL: cwd,
            applicationSupportURL: appSupport,
            fileExists: existing([local.path])
        )

        XCTAssertEqual(resolved.path, local.path)
    }

    func testMissingExplicitPathDoesNotFallBack() {
        let appCache = appSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors")

        XCTAssertThrowsError(
            try CLIWeightsResolver.resolve(
                explicitPath: "/missing/custom.safetensors",
                environment: [:],
                currentDirectoryURL: cwd,
                applicationSupportURL: appSupport,
                fileExists: existing([appCache.path])
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIWeightsResolutionError,
                .explicitPathMissing(URL(fileURLWithPath: "/missing/custom.safetensors"))
            )
        }
    }

    func testMissingEnvironmentPathDoesNotFallBack() {
        let appCache = appSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors")

        XCTAssertThrowsError(
            try CLIWeightsResolver.resolve(
                explicitPath: nil,
                environment: [CLIWeightsResolver.environmentKey: "/missing/env.safetensors"],
                currentDirectoryURL: cwd,
                applicationSupportURL: appSupport,
                fileExists: existing([appCache.path])
            )
        ) { error in
            XCTAssertEqual(
                error as? CLIWeightsResolutionError,
                .environmentPathMissing(
                    key: CLIWeightsResolver.environmentKey,
                    url: URL(fileURLWithPath: "/missing/env.safetensors")
                )
            )
        }
    }

    func testMissingWeightsDiagnosticMentionsRecoveryOptionsAndSearchedPaths() {
        let appCache = appSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors")
        let local = cwd.appendingPathComponent("model_mlx.safetensors")

        XCTAssertThrowsError(
            try CLIWeightsResolver.resolve(
                explicitPath: nil,
                environment: [:],
                currentDirectoryURL: cwd,
                applicationSupportURL: appSupport,
                fileExists: existing([])
            )
        ) { error in
            let message = error.localizedDescription
            XCTAssertTrue(message.contains("--weights"), message)
            XCTAssertTrue(message.contains(CLIWeightsResolver.environmentKey), message)
            XCTAssertTrue(message.contains(appCache.path), message)
            XCTAssertTrue(message.contains(local.path), message)
        }
    }

    private func existing(_ paths: [String]) -> (String) -> Bool {
        let pathSet = Set(paths)
        return { pathSet.contains($0) }
    }
}
