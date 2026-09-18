// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import Inference
import AudioIO
import TestSupport

final class PerformanceTests: XCTestCase {
    private static let realtimeThroughputMultiplier = 1.0
    private static let maximumResidentSetSizeBytes = 150_000_000

    func testFullPipelineThroughput_30s() async throws {
        try await runPerformanceTest(chunkSeconds: 30.0)
    }

    func testFullPipelineThroughput_5s() async throws {
        try await runPerformanceTest(chunkSeconds: 5.0)
    }

    private func runPerformanceTest(chunkSeconds: Double) async throws {
        let fixtures: [RealAudioFixture]
        do {
            fixtures = try RealFixtureCatalog.requireFixtures()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        let weightsURL: URL
        do {
            weightsURL = try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        let enhancer = try MambaEnhancer(modelWeightsURL: weightsURL)
        let reader = TestAudioFileReader()
        let settings = try InferenceSettings(chunkSeconds: chunkSeconds, overlapPortion: 0.0)

        for fixture in fixtures {
            let contents = try await reader.read(from: fixture.inputURL)
            let inputSamples = contents.downmixedToMonoSamples()

            let start = DispatchTime.now()
            _ = try await collectEnhancedSamples(
                enhancer: enhancer,
                samples: inputSamples,
                sampleRate: contents.sampleRate,
                settings: settings
            )
            let end = DispatchTime.now()

            let nanoTime = end.uptimeNanoseconds - start.uptimeNanoseconds
            let timeInterval = Double(nanoTime) / 1_000_000_000
            let inputDuration = Double(contents.frameCount) / Double(contents.sampleRate)
            let maximumAllowed = inputDuration * Self.realtimeThroughputMultiplier

            print(
                "Performance [\(fixture.label)] (\(chunkSeconds)s chunk): " +
                "\(timeInterval) seconds for \(inputDuration) seconds input"
            )
            XCTAssertLessThanOrEqual(
                timeInterval,
                maximumAllowed,
                """
                [\(fixture.label)] Enhancement exceeded 1:1 realtime for chunkSeconds=\(chunkSeconds).
                elapsed=\(timeInterval)s inputDuration=\(inputDuration)s maxAllowed=\(maximumAllowed)s
                """
            )
        }
    }

    func testPeakRSS() async throws {
        let cliURL = try Self.requireReleaseCLI()
        let timeURL = URL(fileURLWithPath: "/usr/bin/time")
        guard FileManager.default.fileExists(atPath: timeURL.path) else {
            throw XCTSkip("/usr/bin/time is required for Peak RSS measurement")
        }

        let fixtures: [RealAudioFixture]
        do {
            fixtures = try RealFixtureCatalog.requireFixtures()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        let weightsURL: URL
        do {
            weightsURL = try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }

        for fixture in fixtures {
            let result = try runRSSMeasurement(
                timeURL: timeURL,
                cliURL: cliURL,
                fixture: fixture,
                weightsURL: weightsURL
            )

            print(
                "Peak RSS [\(fixture.label)]: \(result.maximumResidentSetSizeBytes) bytes " +
                "(\(result.elapsedSeconds.map { String($0) } ?? "unknown") seconds real)"
            )
            XCTAssertLessThanOrEqual(
                result.maximumResidentSetSizeBytes,
                Self.maximumResidentSetSizeBytes,
                """
                [\(fixture.label)] Peak RSS exceeded limit.
                rss=\(result.maximumResidentSetSizeBytes) bytes max=\(Self.maximumResidentSetSizeBytes) bytes
                """
            )
        }
    }

    private struct RSSMeasurement {
        let maximumResidentSetSizeBytes: Int
        let elapsedSeconds: Double?
    }

    private static func requireReleaseCLI() throws -> URL {
        let candidates = [
            ModelTestPaths.projectRoot.appendingPathComponent("dist/local/speechlens-cli/speechlens-cli"),
            ModelTestPaths.projectRoot.appendingPathComponent(".build/release/speechlens-cli"),
            ModelTestPaths.projectRoot.appendingPathComponent(".build/arm64-apple-macosx/release/speechlens-cli"),
        ]

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            return candidate
        }

        throw XCTSkip("Release CLI not found. Run `Tools/package-local.sh --configuration release` before the Peak RSS gate.")
    }

    private func runRSSMeasurement(
        timeURL: URL,
        cliURL: URL,
        fixture: RealAudioFixture,
        weightsURL: URL
    ) throws -> RSSMeasurement {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("speechlens-rss-\(fixture.label)-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = timeURL
        process.currentDirectoryURL = ModelTestPaths.projectRoot
        process.arguments = [
            "-l",
            cliURL.path,
            "--input", fixture.inputURL.path,
            "--output", outputURL.path,
            "--weights", weightsURL.path,
            "--chunk-seconds", "30.0",
        ]

        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr

        try process.run()
        process.waitUntilExit()

        let stdoutText = Self.readString(from: stdout)
        let stderrText = Self.readString(from: stderr)
        guard process.terminationStatus == 0 else {
            XCTFail(
                """
                RSS measurement failed for \(fixture.label) with status \(process.terminationStatus).
                stdout:
                \(stdoutText)
                stderr:
                \(stderrText)
                """
            )
            return RSSMeasurement(maximumResidentSetSizeBytes: Int.max, elapsedSeconds: nil)
        }

        guard let maxRSS = Self.parseMaximumResidentSetSize(from: stderrText) else {
            XCTFail("Could not parse maximum resident set size for \(fixture.label):\n\(stderrText)")
            return RSSMeasurement(maximumResidentSetSizeBytes: Int.max, elapsedSeconds: nil)
        }

        return RSSMeasurement(
            maximumResidentSetSizeBytes: maxRSS,
            elapsedSeconds: Self.parseElapsedSeconds(from: stderrText)
        )
    }

    private static func readString(from pipe: Pipe) -> String {
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return String(data: data, encoding: .utf8) ?? ""
    }

    private static func parseMaximumResidentSetSize(from output: String) -> Int? {
        for line in output.components(separatedBy: .newlines) {
            guard line.contains("maximum resident set size") else { continue }
            let parts = line.split(separator: " ")
            return parts.compactMap { Int($0) }.first
        }
        return nil
    }

    private static func parseElapsedSeconds(from output: String) -> Double? {
        for line in output.components(separatedBy: .newlines) {
            guard line.contains(" real") else { continue }
            let parts = line.split(separator: " ")
            return parts.compactMap { Double($0) }.first
        }
        return nil
    }
}
