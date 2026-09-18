// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import TestSupport
import XCTest
@testable import MediaIO
@testable import Processing

class UnifiedPipelineTestCase: XCTestCase {
    func heAACFixture() throws -> URL {
        try MediaTestFixtures.requireHEAAC()
    }

    func makeTemporaryDirectory(prefix: String) throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory
    }

    func makeSyntheticInput(
        in directory: URL,
        filename: String,
        encoderArguments: [String],
        durationSeconds: Double = 1.2,
        noiseAmplitude: Double = 0,
        outputMuxer: String? = nil
    ) throws -> URL {
        let sampleRate = 48_000
        let frameCount = Int(Double(sampleRate) * durationSeconds)
        var samples = [Float]()
        samples.reserveCapacity(frameCount * 2)
        var noiseState: UInt32 = 0xA11CE
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let transient: Double = frame == sampleRate / 2 ? 0.5 : 0
            let leftNoise = nextSyntheticNoise(state: &noiseState) * noiseAmplitude
            let rightNoise = nextSyntheticNoise(state: &noiseState) * noiseAmplitude
            samples.append(Float(0.25 * sin(2 * .pi * 440 * time) + transient + leftNoise))
            samples.append(Float(0.2 * sin(2 * .pi * 880 * time) - transient + rightNoise))
        }
        let raw = directory.appendingPathComponent("synthetic.f32le")
        try samples.withUnsafeBytes { try Data($0).write(to: raw, options: .atomic) }

        let output = directory.appendingPathComponent(filename)
        try run([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", raw.path,
        ] + encoderArguments + (outputMuxer.map { ["-f", $0] } ?? []) + [output.path])
        return output
    }

    func makeSyntheticMultistreamMP4(
        in directory: URL,
        audioEncoderArguments: [String] = [
            "-c:a", "aac_at", "-aac_at_mode", "abr", "-b:a", "64k",
        ],
        timecode: String? = nil
    ) throws -> URL {
        let sampleRate = 48_000
        let durationSeconds = 2
        let frameCount = sampleRate * durationSeconds
        let videoWidth = 64
        let videoHeight = 48
        let videoFrameCount = 24
        let video = directory.appendingPathComponent("video.yuv")
        var videoBytes = [UInt8]()
        videoBytes.reserveCapacity(videoFrameCount * videoWidth * videoHeight * 3 / 2)
        for frame in 0..<videoFrameCount {
            for row in 0..<videoHeight {
                for column in 0..<videoWidth {
                    videoBytes.append(UInt8((column * 3 + row * 5 + frame * 11) % 256))
                }
            }
            videoBytes.append(contentsOf: repeatElement(
                UInt8((128 + frame * 7) % 256), count: videoWidth * videoHeight / 4
            ))
            videoBytes.append(contentsOf: repeatElement(
                UInt8((64 + frame * 13) % 256), count: videoWidth * videoHeight / 4
            ))
        }
        try Data(videoBytes).write(to: video, options: .atomic)

        let languages = [
            (code: "eng", title: "English", left: 293.66, right: 587.33),
            (code: "fra", title: "French", left: 349.23, right: 698.46),
            (code: "deu", title: "German", left: 440.00, right: 880.00),
        ]
        var audioInputs = [URL]()
        for (languageIndex, language) in languages.enumerated() {
            var samples = [Float]()
            samples.reserveCapacity(frameCount * 2)
            var noiseState = UInt32(0x51A7E + languageIndex)
            for frame in 0..<frameCount {
                let time = Double(frame) / Double(sampleRate)
                let transient = frame == sampleRate ? 0.35 : 0.0
                let leftNoise = nextSyntheticNoise(state: &noiseState) * 0.22
                let rightNoise = nextSyntheticNoise(state: &noiseState) * 0.22
                samples.append(Float(0.24 * sin(2 * .pi * language.left * time) + transient + leftNoise))
                samples.append(Float(0.19 * sin(2 * .pi * language.right * time) - transient + rightNoise))
            }
            let raw = directory.appendingPathComponent("\(language.code).f32le")
            try samples.withUnsafeBytes { try Data($0).write(to: raw, options: .atomic) }
            audioInputs.append(raw)
        }

        let output = directory.appendingPathComponent("multilingual.mp4")
        var arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "rawvideo", "-pixel_format", "yuv420p",
            "-video_size", "\(videoWidth)x\(videoHeight)", "-framerate", "12",
            "-i", video.path,
        ]
        for input in audioInputs {
            arguments += ["-f", "f32le", "-ar", "\(sampleRate)", "-ac", "2", "-i", input.path]
        }
        arguments += [
            "-map", "0:v:0", "-map", "1:a:0", "-map", "2:a:0", "-map", "3:a:0",
            "-metadata:s:a:0", "language=eng", "-metadata:s:a:0", "handler_name=English",
            "-metadata:s:a:1", "language=fra", "-metadata:s:a:1", "handler_name=French",
            "-metadata:s:a:2", "language=deu", "-metadata:s:a:2", "handler_name=German",
            "-disposition:a:0", "default", "-disposition:a:1", "forced", "-disposition:a:2", "0",
            "-c:v", "mpeg4", "-q:v", "5",
        ] + audioEncoderArguments + [
            output.path,
        ]
        if let timecode {
            arguments.insert(
                contentsOf: [
                    "-metadata:s:v:0", "timecode=\(timecode)",
                    "-write_tmcd", "1",
                ],
                at: arguments.count - 1
            )
        }
        try run(arguments)
        return output
    }

    func nextSyntheticNoise(state: inout UInt32) -> Double {
        state = state &* 1_664_525 &+ 1_013_904_223
        return Double(state) / Double(UInt32.max) * 2 - 1
    }

    func aacABRBitRateTolerance(target: Int) -> Int {
        max(7_000, Int((Double(target) * 0.1).rounded(.up)))
    }

    @discardableResult
    func assertIdentityTransaction(
        input: URL,
        output: URL,
        expectedContainer: MediaContainer,
        expectedCodec: String,
        expectedBitRate: Int? = nil,
        expectedBitRateTolerance: Int = 1_000,
        expectedBitDepth: Int? = nil,
        clock: MediaProcessingClock = .continuous
    ) async throws -> MediaProcessingResult {
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let preparer = MediaJobPreparer(engine: engine)
        let inspection = try await preparer.inspect(inputURL: input)
        let selected = try XCTUnwrap(inspection.mediaInspection.audioTracks.first?.audioDescriptor)
        XCTAssertEqual(selected.sampleRate, 48_000)
        XCTAssertEqual(selected.channelCount, 2)

        let job = try await preparer.prepare(
            inspection: inspection,
            selectedAudioStreamIndex: inspection.mediaInspection.suggestedAudioStreamIndex,
            options: .standard
        ) { plan in
            XCTAssertEqual(plan.outputContainer, expectedContainer)
            return output
        }
        if let expectedBitRate {
            XCTAssertEqual(job.mediaPlan.execution.plannedBitRate, expectedBitRate)
        }
        let result = try await MediaFileEnhancementPipeline(
            enhancer: IdentityEnhancer(),
            engine: engine,
            clock: clock
        ).process(job: job, settings: .standard)
        XCTAssertEqual(result.outputInfo.selectedAudio.sampleRate, 48_000)
        XCTAssertEqual(result.outputInfo.selectedAudio.channelCount, 2)
        XCTAssertGreaterThan(result.inputInfo.selectedAudio.validFrameCount ?? 0, 0)
        XCTAssertGreaterThan(result.outputInfo.selectedAudio.durationSeconds, 0)
        XCTAssertTrue(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(result.timings.isConsistent)
        XCTAssertGreaterThanOrEqual(result.timings.committing, .zero)
        XCTAssertEqual(
            result.timings.total,
            result.timings.preflight
                + result.timings.enhancementPass
                + result.timings.validating
                + result.timings.committing
        )

        let outputInspection = try await engine.inspect(output)
        XCTAssertEqual(outputInspection.media.container, expectedContainer)
        let outputAudio = try XCTUnwrap(outputInspection.media.audioTracks.first?.audioDescriptor)
        XCTAssertEqual(outputAudio.sampleRate, 48_000)
        XCTAssertEqual(outputAudio.channelCount, 2)
        if let expectedBitDepth {
            XCTAssertEqual(outputAudio.codec.bitsPerChannel, expectedBitDepth)
        }
        XCTAssertEqual(
            outputInspection.media.tracks.first(where: \.isAudio)?.codecName,
            expectedCodec
        )
        if let expectedBitRate {
            XCTAssertEqual(
                try XCTUnwrap(outputAudio.estimatedBitRate),
                expectedBitRate,
                accuracy: expectedBitRateTolerance
            )
        }
        return result
    }

    func packetHash(_ url: URL, stream: Int) throws -> String {
        try run([
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-i", url.path, "-map", "0:\(stream)", "-c", "copy",
            "-f", "hash", "-hash", "sha256", "pipe:1",
        ])
    }

    @discardableResult
    func run(_ arguments: [String]) throws -> String {
        try MediaTestRuntime.runFFmpeg(arguments)
    }
}

final class SequencedProcessingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let instants: [ContinuousClock.Instant]
    private var index = 0

    init(instants: [ContinuousClock.Instant]) {
        self.instants = instants
    }

    func now() -> ContinuousClock.Instant {
        lock.withLock {
            precondition(index < instants.count, "Processing clock exhausted")
            defer { index += 1 }
            return instants[index]
        }
    }

    var consumedCount: Int {
        lock.withLock { index }
    }
}

actor IdentityEnhancer: StreamingSpeechEnhancer {
    func makeSession(
        sampleRate: Int,
        settings: InferenceSettings
    ) async throws -> any SpeechEnhancementSession {
        _ = sampleRate
        _ = settings
        return IdentitySession()
    }
}

private final class IdentitySession: SpeechEnhancementSession, @unchecked Sendable {
    let recommendedInputFrameCount = 16_384

    func append(_ samples: [Float]) async throws -> [Float] { samples }
    func finish() async throws -> [Float] { [] }
}
