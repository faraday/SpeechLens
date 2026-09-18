// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import TestSupport
import XCTest
@testable import MediaIO
@testable import Processing

final class UnifiedStreamRoutingTests: UnifiedPipelineTestCase {
    func testEverySelectedPositionKeepsOtherLanguageTracksPacketCopied() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-Multitrack")
        let input = try makeSyntheticMultistreamMP4(in: directory)

        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let preparer = MediaJobPreparer(engine: engine)
        let inspection = try await preparer.inspect(inputURL: input)
        XCTAssertEqual(inspection.mediaInspection.tracks.map(\.mediaType), [
            "vide", "soun", "soun", "soun",
        ])
        XCTAssertEqual(inspection.mediaInspection.tracks.first?.codecName, "mpeg4")
        XCTAssertEqual(inspection.mediaInspection.audioTracks.count, 3)
        XCTAssertEqual(
            inspection.mediaInspection.audioTracks.compactMap(\.audioDescriptor).map(\.sampleRate),
            [48_000, 48_000, 48_000]
        )
        XCTAssertEqual(
            inspection.mediaInspection.audioTracks.compactMap(\.audioDescriptor).map(\.channelCount),
            [2, 2, 2]
        )
        XCTAssertEqual(
            inspection.mediaInspection.audioTracks.map(\.languageCode),
            ["eng", "fra", "deu"]
        )
        XCTAssertEqual(
            inspection.mediaInspection.audioTracks.map(\.title),
            ["English", "French", "German"]
        )
        XCTAssertEqual(
            inspection.mediaInspection.tracks.map(\.dispositions),
            [["default"], ["default"], ["forced"], []]
        )
        let sourceHashes = try Dictionary(uniqueKeysWithValues:
            inspection.mediaInspection.tracks.map {
                ($0.streamIndex, try packetHash(input, stream: $0.streamIndex))
            }
        )
        for selected in inspection.mediaInspection.audioTracks {
            let output = directory.appendingPathComponent(
                "enhanced-\(selected.streamIndex).mp4"
            )
            let job = try await preparer.prepare(
                inspection: inspection,
                selectedAudioStreamIndex: selected.streamIndex
            ) { _ in output }
            XCTAssertEqual(job.mediaPlan.execution.plannedBitRate, 80_000)
            let transaction = try await MediaFileEnhancementPipeline(
                enhancer: IdentityEnhancer(),
                engine: engine
            ).process(job: job, settings: .standard)

            let result = try await engine.inspect(output)
            XCTAssertEqual(result.media.tracks.map(\.mediaType), [
                "vide", "soun", "soun", "soun",
            ])
            XCTAssertEqual(
                result.media.audioTracks.map(\.languageCode),
                ["eng", "fra", "deu"]
            )
            XCTAssertEqual(
                result.media.tracks.filter(\.isAudio).map(\.title),
                inspection.mediaInspection.tracks.filter(\.isAudio).map(\.title)
            )
            XCTAssertEqual(
                result.media.tracks.map(\.dispositions),
                inspection.mediaInspection.tracks.map(\.dispositions)
            )
            XCTAssertEqual(transaction.outputInfo.selectedAudio.sampleRate, 48_000)
            XCTAssertEqual(transaction.outputInfo.selectedAudio.channelCount, 2)
            // FFprobe reports a duration-derived average, while aac_at ABR is a
            // target rather than a per-file CBR guarantee. Keep this narrow enough
            // to catch a missing bitrate argument without coupling to mux overhead.
            XCTAssertEqual(
                try XCTUnwrap(transaction.outputInfo.selectedAudio.estimatedBitRate),
                80_000,
                accuracy: aacABRBitRateTolerance(target: 80_000)
            )
            for stream in inspection.mediaInspection.tracks
                where stream.streamIndex != selected.streamIndex {
                XCTAssertEqual(
                    try packetHash(output, stream: stream.streamIndex),
                    sourceHashes[stream.streamIndex]
                )
            }
        }
    }

    func testSyntheticALACMP4KeepsVideoAndOtherAudioTracksPacketCopied() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-ALAC-Multitrack")
        let input = try makeSyntheticMultistreamMP4(
            in: directory,
            audioEncoderArguments: ["-c:a", "alac"]
        )
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let preparer = MediaJobPreparer(engine: engine)
        let inspection = try await preparer.inspect(inputURL: input)
        XCTAssertEqual(inspection.mediaInspection.tracks.filter(\.isAudio).map(\.codecName), [
            "alac", "alac", "alac",
        ])
        let selected = try XCTUnwrap(inspection.mediaInspection.audioTracks.first)
        let sourceHashes = try Dictionary(uniqueKeysWithValues:
            inspection.mediaInspection.tracks.map {
                ($0.streamIndex, try packetHash(input, stream: $0.streamIndex))
            }
        )
        let output = directory.appendingPathComponent("enhanced.mp4")
        let job = try await preparer.prepare(
            inspection: inspection,
            selectedAudioStreamIndex: selected.streamIndex
        ) { _ in output }
        XCTAssertEqual(job.mediaPlan.execution.encoder, .alac24)
        _ = try await MediaFileEnhancementPipeline(
            enhancer: IdentityEnhancer(),
            engine: engine
        ).process(job: job, settings: .standard)

        let result = try await engine.inspect(output)
        XCTAssertEqual(result.media.container, .mp4)
        XCTAssertEqual(result.media.tracks.first(where: \.isAudio)?.codecName, "alac")
        XCTAssertEqual(result.media.tracks.first?.codecName, "mpeg4")
        for stream in inspection.mediaInspection.tracks where stream.streamIndex != selected.streamIndex {
            XCTAssertEqual(
                try packetHash(output, stream: stream.streamIndex),
                sourceHashes[stream.streamIndex]
            )
        }
    }

    func testSyntheticTimecodeMP4IgnoresAuxiliaryStreamsDuringValidation() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-Timecode-MP4")
        let input = try makeSyntheticMultistreamMP4(
            in: directory,
            timecode: "01:00:00:00"
        )
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let preparer = MediaJobPreparer(engine: engine)
        let inspection = try await preparer.inspect(inputURL: input)
        XCTAssertTrue(inspection.mediaInspection.tracks.contains {
            $0.mediaType == "meta"
        })
        let sourceVideoHash = try packetHash(input, stream: 0)
        let output = directory.appendingPathComponent("enhanced.mp4")
        let job = try await preparer.prepare(
            inspection: inspection,
            selectedAudioStreamIndex: inspection.mediaInspection.suggestedAudioStreamIndex
        ) { _ in output }

        let transaction = try await MediaFileEnhancementPipeline(
            enhancer: IdentityEnhancer(),
            engine: engine
        ).process(job: job, settings: .standard)
        let outputInspection = try await engine.inspect(output)
        XCTAssertEqual(
            outputInspection.media.tracks.filter(\.isUserFacing).map(\.mediaType),
            inspection.mediaInspection.tracks.filter(\.isUserFacing).map(\.mediaType)
        )
        XCTAssertEqual(try packetHash(output, stream: 0), sourceVideoHash)
        XCTAssertEqual(transaction.outputInfo.selectedAudio.sampleRate, 48_000)
        XCTAssertEqual(transaction.outputInfo.selectedAudio.channelCount, 2)
    }
}
