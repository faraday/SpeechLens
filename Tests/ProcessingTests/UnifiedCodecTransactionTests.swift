// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import TestSupport
import XCTest
@testable import MediaIO
@testable import Processing

final class UnifiedCodecTransactionTests: UnifiedPipelineTestCase {
    func testInjectedClockPartitionsActualPipelineBoundariesExactly()
        async throws
    {
        let directory = try makeTemporaryDirectory(
            prefix: "SpeechLens-Timing-Boundaries"
        )
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.wav",
            encoderArguments: ["-c:a", "pcm_s16le"]
        )
        let start = ContinuousClock.now
        let clock = SequencedProcessingClock(instants: [
            start,
            start.advanced(by: .seconds(2)),
            start.advanced(by: .seconds(7)),
            start.advanced(by: .seconds(8)),
            start.advanced(by: .seconds(11)),
            start.advanced(by: .seconds(13)),
        ])

        let result = try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.wav"),
            expectedContainer: .wav,
            expectedCodec: "pcm_f32le",
            expectedBitDepth: 32,
            clock: MediaProcessingClock(now: clock.now)
        )

        XCTAssertEqual(result.timings.preflight, .seconds(2))
        XCTAssertEqual(result.timings.enhancing, .seconds(5))
        XCTAssertEqual(result.timings.finalizing, .seconds(1))
        XCTAssertEqual(result.timings.enhancementPass, .seconds(6))
        XCTAssertEqual(result.timings.validating, .seconds(3))
        XCTAssertEqual(result.timings.committing, .seconds(2))
        XCTAssertEqual(result.timings.total, .seconds(13))
        XCTAssertEqual(clock.consumedCount, 6)
    }

    func testHEAACM4AMP4AndMOVRunThroughDirectUnifiedTransactions() async throws {
        let fixture = try heAACFixture()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeechLens-HEAAC-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        var inputs: [(URL, MediaContainer)] = [(fixture, .m4a)]
        for container in [MediaContainer.mp4, .mov] {
            let remuxed = directory.appendingPathComponent(
                "input.\(container.preferredExtension)"
            )
            try run([
                "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
                "-i", fixture.path, "-map", "0:a:0", "-c", "copy", remuxed.path,
            ])
            inputs.append((remuxed, container))
        }
        for (input, container) in inputs {
            try await assertIdentityTransaction(
                input: input,
                output: directory.appendingPathComponent(
                    "enhanced.\(container.preferredExtension)"
                ),
                expectedContainer: container,
                expectedCodec: "aac"
            )
        }
    }

    func testSyntheticMP3AVITransactsToNativeRateMP3() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-AVI")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.avi",
            encoderArguments: ["-c:a", "libmp3lame", "-b:a", "96k"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.avi"),
            expectedContainer: .avi,
            expectedCodec: "mp3",
            expectedBitRate: 160_000
        )
    }

    func testVideoBearingMP3AVICompletesReplacementTransaction() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-Video-AVI")
        let audio = try makeSyntheticInput(
            in: directory,
            filename: "audio.avi",
            encoderArguments: ["-c:a", "libmp3lame", "-b:a", "96k"],
            durationSeconds: 3
        )
        let video = directory.appendingPathComponent("video.yuv")
        let width = 64
        let height = 48
        let frameCount = 72
        var bytes = Data()
        bytes.reserveCapacity(frameCount * width * height * 3 / 2)
        for frame in 0..<frameCount {
            bytes.append(contentsOf: repeatElement(
                UInt8(frame % 256), count: width * height
            ))
            bytes.append(contentsOf: repeatElement(
                UInt8((96 + frame) % 256), count: width * height / 4
            ))
            bytes.append(contentsOf: repeatElement(
                UInt8((160 + frame) % 256), count: width * height / 4
            ))
        }
        try bytes.write(to: video, options: .atomic)
        let input = directory.appendingPathComponent("input.avi")
        try run([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pixel_format", "yuv420p",
            "-video_size", "\(width)x\(height)", "-framerate", "24",
            "-i", video.path,
            "-i", audio.path,
            "-map", "0:v:0", "-map", "1:a:0",
            "-c:v", "mpeg4", "-q:v", "5", "-c:a", "copy",
            input.path,
        ])
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.avi"),
            expectedContainer: .avi,
            expectedCodec: "mp3",
            expectedBitRate: 160_000
        )
    }

    func testSyntheticPCMAVITransactsToNativeRatePCM() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-PCM-AVI")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.avi",
            encoderArguments: ["-c:a", "pcm_s24le"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.avi"),
            expectedContainer: .avi,
            expectedCodec: "pcm_s24le",
            expectedBitDepth: 24
        )
    }

    func testSyntheticMP3TransactsToSourceAdaptiveMP3() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-MP3")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mp3",
            encoderArguments: ["-c:a", "libmp3lame", "-b:a", "96k"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mp3"),
            expectedContainer: .mp3,
            expectedCodec: "mp3",
            expectedBitRate: 160_000
        )
    }

    func testSyntheticAACAVIIsRejectedBeforeModelLoading() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-AAC-AVI")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.avi",
            encoderArguments: ["-c:a", "aac_at", "-aac_at_mode", "abr", "-b:a", "128k"],
            durationSeconds: 3,
            noiseAmplitude: 0.22
        )
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        do {
            _ = try await MediaJobPreparer(engine: engine).inspect(inputURL: input)
            XCTFail("AAC-in-AVI unexpectedly passed inspection")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains(
                "AAC audio inside AVI is not supported"
            ))
        }
    }

    func testMixedAACAndMP3AVILeavesAACUnavailableAndMP3Selectable() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-Mixed-AAC-AVI")
        let aac = try makeSyntheticInput(
            in: directory,
            filename: "aac.avi",
            encoderArguments: ["-c:a", "aac_at", "-b:a", "96k"]
        )
        let mp3 = try makeSyntheticInput(
            in: directory,
            filename: "mp3.avi",
            encoderArguments: ["-c:a", "libmp3lame", "-b:a", "96k"]
        )
        let input = directory.appendingPathComponent("input.avi")
        try run([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", aac.path, "-i", mp3.path,
            "-map", "0:a:0", "-map", "1:a:0",
            "-c", "copy",
            input.path,
        ])
        let inspection = try await UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        ).inspect(input)
        XCTAssertEqual(inspection.media.audioTracks.count, 2)
        XCTAssertTrue(inspection.media.audioTracks[0].unavailableReason?.contains(
            "AAC audio inside AVI is not supported"
        ) == true)
        XCTAssertTrue(inspection.media.audioTracks[1].isSelectable)
        XCTAssertEqual(
            inspection.media.suggestedAudioStreamIndex,
            inspection.media.audioTracks[1].streamIndex
        )
    }

    func testSyntheticAACM4ATransactsToSourceAwareAAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-AAC-M4A")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.m4a",
            encoderArguments: ["-c:a", "aac_at", "-aac_at_mode", "abr", "-b:a", "128k"],
            durationSeconds: 3,
            noiseAmplitude: 0.22
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.m4a"),
            expectedContainer: .m4a,
            expectedCodec: "aac",
            expectedBitRate: 144_000,
            expectedBitRateTolerance: aacABRBitRateTolerance(target: 144_000)
        )
    }

    func testSyntheticHighBitRateAACM4ATransactsToHighestCompatibleTarget() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-AAC-HighBitRate")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.m4a",
            encoderArguments: ["-c:a", "aac_at", "-aac_at_mode", "abr", "-b:a", "320k"],
            durationSeconds: 3,
            noiseAmplitude: 0.22
        )
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let preparer = MediaJobPreparer(engine: engine)
        let inspection = try await preparer.inspect(inputURL: input)
        let requested = AdaptiveAACBitRate.requestedBitRate(
            source: try XCTUnwrap(inspection.mediaInspection.audioTracks.first?.audioDescriptor)
        )
        XCTAssertEqual(requested, 320_000)
        let output = directory.appendingPathComponent("enhanced.m4a")
        let job = try await preparer.prepare(
            inspection: inspection,
            selectedAudioStreamIndex: inspection.mediaInspection.suggestedAudioStreamIndex
        ) { _ in output }
        let selectedTarget = try XCTUnwrap(job.mediaPlan.execution.plannedBitRate)
        XCTAssertTrue(AdaptiveAACBitRate.candidateBitRates(requested: requested).contains(selectedTarget))

        let transaction = try await MediaFileEnhancementPipeline(
            enhancer: IdentityEnhancer(),
            engine: engine
        ).process(job: job, settings: .standard)
        XCTAssertEqual(transaction.outputInfo.selectedAudio.sampleRate, 48_000)
        XCTAssertEqual(transaction.outputInfo.selectedAudio.channelCount, 2)
        let outputInspection = try await engine.inspect(output)
        XCTAssertEqual(outputInspection.media.tracks.first(where: \.isAudio)?.codecName, "aac")
        XCTAssertEqual(
            try XCTUnwrap(transaction.outputInfo.selectedAudio.estimatedBitRate),
            selectedTarget,
            accuracy: aacABRBitRateTolerance(target: selectedTarget)
        )
    }

    func testSyntheticAACMOVTransactsToSourceAwareAAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-AAC-MOV")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mov",
            encoderArguments: ["-c:a", "aac_at", "-aac_at_mode", "abr", "-b:a", "128k"],
            durationSeconds: 3,
            noiseAmplitude: 0.22
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mov"),
            expectedContainer: .mov,
            expectedCodec: "aac",
            expectedBitRate: 144_000,
            expectedBitRateTolerance: aacABRBitRateTolerance(target: 144_000)
        )
    }

    func testSyntheticALACMOVTransactsToALAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-ALAC-MOV")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mov",
            encoderArguments: ["-c:a", "alac"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mov"),
            expectedContainer: .mov,
            expectedCodec: "alac",
            expectedBitDepth: 24
        )
    }

    func testSyntheticALACMP4TransactsToALAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-ALAC-MP4")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mp4",
            encoderArguments: ["-c:a", "alac"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mp4"),
            expectedContainer: .mp4,
            expectedCodec: "alac",
            expectedBitDepth: 24
        )
    }

    func testSyntheticPCMMOVRetainsSourceRepresentation() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-PCM-MOV")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mov",
            encoderArguments: ["-c:a", "pcm_s24le"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mov"),
            expectedContainer: .mov,
            expectedCodec: "pcm_s24le",
            expectedBitDepth: 24
        )
    }

    func testSyntheticPCMMP4RetainsSourceRepresentation() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-PCM-MP4")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mp4",
            encoderArguments: ["-c:a", "pcm_s16le"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mp4"),
            expectedContainer: .mp4,
            expectedCodec: "pcm_s16le",
            expectedBitDepth: 16
        )
    }

    func testSyntheticFLACMOVTransactsToALAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-FLAC-MOV")
        // FFmpeg cannot mux FLAC into true MOV. The MOV extension selects the
        // production MOV recipe while the MP4 muxer supplies a decodable input.
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mov",
            encoderArguments: [
                "-c:a", "flac", "-metadata:s:a:0", "language=eng",
            ],
            outputMuxer: "mp4"
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mov"),
            expectedContainer: .mov,
            expectedCodec: "alac",
            expectedBitDepth: 24
        )
    }

    func testSyntheticFLACMP4TransactsToFLAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-FLAC-MP4")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.mp4",
            encoderArguments: ["-c:a", "flac"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.mp4"),
            expectedContainer: .mp4,
            expectedCodec: "flac",
            expectedBitDepth: 24
        )
    }

    func testSyntheticFLACTransactsToNativeRateFLAC() async throws {
        let directory = try makeTemporaryDirectory(prefix: "SpeechLens-FLAC")
        let input = try makeSyntheticInput(
            in: directory,
            filename: "input.flac",
            encoderArguments: ["-c:a", "flac"]
        )
        try await assertIdentityTransaction(
            input: input,
            output: directory.appendingPathComponent("enhanced.flac"),
            expectedContainer: .flac,
            expectedCodec: "flac"
        )
    }
}
