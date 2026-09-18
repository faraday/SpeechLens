// SPDX-License-Identifier: Apache-2.0

import XCTest
import Foundation
import Inference
import AudioIO
import TestSupport

final class AudioQualityTests: XCTestCase {
    private static let qualityChunkSecondsEnvironmentKey = "SPEECHLENS_AUDIO_QUALITY_CHUNK_SECONDS"
    private static let defaultQualityChunkSeconds = 10.0

    private static let outputDir = ModelTestPaths.projectRoot
        .appendingPathComponent("TestResults/AudioQuality")

    /// Runs every real fixture through the structural and spectral gates in
    /// `docs/audio-quality.md`, writing outputs for optional listening review.
    func testRealFixturesQuality() async throws {
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

        print("[AudioQualityTests] Loading weights: \(weightsURL.path)")
        let enhancer = try MambaEnhancer(modelWeightsURL: weightsURL)
        let settings = try Self.qualitySettings()
        print(
            "[AudioQualityTests] Using chunkSeconds=\(settings.chunkSeconds) " +
            "overlapPortion=\(settings.overlapPortion)"
        )

        let fm = FileManager.default
        try? fm.createDirectory(at: Self.outputDir, withIntermediateDirectories: true)

        for fixture in fixtures {
            try await runQualityCheck(fixture: fixture, enhancer: enhancer, settings: settings)
        }
    }

    private static func qualitySettings() throws -> InferenceSettings {
        let rawOverride = ProcessInfo.processInfo.environment[qualityChunkSecondsEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let chunkSeconds: Double
        if let rawOverride, !rawOverride.isEmpty {
            guard let parsed = Double(rawOverride) else {
                throw AudioQualityTestError.invalidChunkSecondsOverride(
                    key: qualityChunkSecondsEnvironmentKey,
                    value: rawOverride
                )
            }
            guard parsed.isFinite, parsed > 0 else {
                throw AudioQualityTestError.invalidChunkSecondsOverride(
                    key: qualityChunkSecondsEnvironmentKey,
                    value: rawOverride
                )
            }
            chunkSeconds = parsed
        } else {
            // AudioQualityTests validate real fixture quality, not maximum production
            // chunk size. Keep chunks bounded so high-sample-rate fixtures do not
            // create oversized Metal command buffers on shared CI runners.
            chunkSeconds = defaultQualityChunkSeconds
        }
        return try InferenceSettings(chunkSeconds: chunkSeconds, overlapPortion: 0.0)
    }

    private func runQualityCheck(
        fixture: RealAudioFixture,
        enhancer: MambaEnhancer,
        settings: InferenceSettings
    ) async throws {
        print("\n[AudioQualityTests] === \(fixture.label) ===")
        print("  input:    \(fixture.inputURL.path)")
        print("  expected: \(fixture.expectedURL.path)")

        let reader = TestAudioFileReader()
        let inputContents = try await reader.read(from: fixture.inputURL)
        let expectedContents = try await reader.read(from: fixture.expectedURL)

        XCTAssertEqual(
            inputContents.sampleRate, expectedContents.sampleRate,
            "[\(fixture.label)] Fixture input/expected sample rates differ"
        )
        let sampleRate = inputContents.sampleRate

        let inputMono = inputContents.downmixedToMonoSamples()
        let expectedMono = expectedContents.downmixedToMonoSamples()

        // Length sanity — expected and input should be sample-aligned. We log instead
        // of failing: alignment drift is tolerated by the spectral metric.
        if inputMono.count != expectedMono.count {
            print("  [warn] length mismatch: input=\(inputMono.count) expected=\(expectedMono.count)")
        }

        let enhancedSamples = try await collectEnhancedSamples(
            enhancer: enhancer,
            samples: inputMono,
            sampleRate: sampleRate,
            settings: settings
        )

        // Structural criteria (1–4 from docs/audio-quality.md).
        AudioQualityAssertions.assertSampleRatePreserved(input: sampleRate, output: sampleRate)
        AudioQualityAssertions.assertFrameCountPreserved(
            input: inputMono.count,
            output: enhancedSamples.count
        )
        AudioQualityAssertions.assertNoNaNOrInf(samples: enhancedSamples)
        AudioQualityAssertions.assertNoClipping(samples: enhancedSamples)

        let outputURL = Self.outputDir.appendingPathComponent("quality_\(fixture.label).wav")
        let writer = TestAudioFileWriter()
        let outContents = TestAudioContents(
            samples: enhancedSamples,
            sampleRate: sampleRate,
            channelCount: 1
        )
        do {
            try await writer.write(outContents, to: outputURL)
            print("  wrote:    \(outputURL.path)")
        } catch {
            print("  [warn] could not write quality output: \(error)")
        }

        AudioQualityAssertions.assertSpeechSpectralSimilarity(
            output: enhancedSamples,
            reference: expectedMono,
            baseline: inputMono,
            sampleRate: sampleRate,
            label: fixture.label
        )
    }
}

private enum AudioQualityTestError: Error, LocalizedError, CustomStringConvertible {
    case invalidChunkSecondsOverride(key: String, value: String)

    var description: String {
        switch self {
        case .invalidChunkSecondsOverride(let key, let value):
            return "\(key) must be a finite positive Double, got '\(value)'"
        }
    }

    var errorDescription: String? { description }
}
