// SPDX-License-Identifier: Apache-2.0

import XCTest
import AudioIO
import Inference
import TestSupport
@testable import MediaIO
@testable import Processing

final class MultichannelIdentityTests: XCTestCase {
    func testSerialMultichannelPreservesLayoutAtSupportedRates() async throws {
        let enhancer = try MambaEnhancer(modelWeightsURL: try weightsURL())

        for sampleRate in [16_000, 44_100, 48_000] {
            let channels = (0..<4).map {
                speechLikeSignal(sampleRate: sampleRate, frameCount: sampleRate, variant: $0)
            }
            for channelCount in [1, 2, 4] {
                let inputChannels = Array(channels.prefix(channelCount))
                let directory = try temporaryDirectory()
                defer { try? FileManager.default.removeItem(at: directory) }
                let inputURL = directory.appendingPathComponent("input.wav")
                let outputURL = directory.appendingPathComponent("output.wav")
                try TestAudioFileWriter().writeSync(
                    TestAudioContents(planarChannels: inputChannels, sampleRate: sampleRate),
                    to: inputURL
                )
                let decodedInput = try TestAudioFileReader().readSync(from: inputURL).planarChannels()
                var standalone = [[Float]]()
                for channel in decodedInput {
                    standalone.append(try await collectEnhancedSamples(
                        enhancer: enhancer,
                        samples: channel,
                        sampleRate: sampleRate,
                        settings: .standard
                    ))
                }
                let standaloneURL = directory.appendingPathComponent("standalone.wav")
                try TestAudioFileWriter().writeSync(
                    TestAudioContents(planarChannels: standalone, sampleRate: sampleRate),
                    to: standaloneURL
                )
                let standaloneFileChannels = try TestAudioFileReader()
                    .readSync(from: standaloneURL)
                    .planarChannels()
                let engine = UnifiedFFmpegMediaEngine(
                    executableURL: MediaTestRuntime.ffmpegURL,
                    probeExecutableURL: MediaTestRuntime.ffprobeURL
                )
                let preparer = MediaJobPreparer(engine: engine)
                let inspection = try await preparer.inspect(inputURL: inputURL)
                let job = try await preparer.prepare(
                    inspection: inspection,
                    selectedAudioStreamIndex: inspection.mediaInspection.suggestedAudioStreamIndex
                ) { _ in outputURL }
                let result = try await MediaFileEnhancementPipeline(
                    enhancer: enhancer,
                    engine: engine
                ).process(
                    job: job,
                    settings: .standard
                )
                let outputContents = try TestAudioFileReader().readSync(from: outputURL)
                let outputChannels = try outputContents.planarChannels()

                XCTAssertEqual(result.outputInfo.selectedAudio.sampleRate, sampleRate)
                XCTAssertEqual(result.outputInfo.selectedAudio.channelCount, channelCount)
                XCTAssertEqual(outputContents.frameCount, inputChannels[0].count)
                XCTAssertEqual(outputChannels.count, channelCount)
                for channelIndex in 0..<channelCount {
                    XCTAssertEqual(outputChannels[channelIndex].count, inputChannels[0].count)
                    XCTAssertTrue(outputChannels[channelIndex].allSatisfy(\.isFinite))
                    let maximumDifference = zip(
                        outputChannels[channelIndex],
                        standaloneFileChannels[channelIndex]
                    ).map { abs($0 - $1) }.max() ?? 0
                    XCTAssertLessThanOrEqual(
                        maximumDifference,
                        1e-5,
                        "\(sampleRate) Hz, \(channelCount) channels, channel \(channelIndex)"
                    )
                }
            }
        }
    }

    private func weightsURL() throws -> URL {
        do {
            return try ModelTestPaths.requireConvertedWeights()
        } catch {
            throw XCTSkip(String(describing: error))
        }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeechLens-MultichannelIdentityTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func speechLikeSignal(sampleRate: Int, frameCount: Int, variant: Int) -> [Float] {
        let carrier = Double(310 + variant * 173)
        let overtone = Double(870 + variant * 211)
        let envelopeRate = Double(3 + variant)
        return (0..<frameCount).map { index in
            let time = Double(index) / Double(sampleRate)
            let envelope = 0.55 + 0.45 * sin(2 * Double.pi * envelopeRate * time)
            let sample = sin(2 * Double.pi * carrier * time)
                + 0.35 * sin(2 * Double.pi * overtone * time + Double(variant))
            return Float(0.08 * envelope * sample)
        }
    }
}
