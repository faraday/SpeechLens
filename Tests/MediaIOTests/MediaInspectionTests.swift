// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
import XCTest
@testable import MediaIO

final class MediaInspectionTests: XCTestCase {
    func testAttachedPicturesAreUserFacingStreams() {
        let artwork = MediaStream(
            streamIndex: 4,
            mediaType: "attm",
            codecName: "mjpeg",
            isEnabled: true,
            languageCode: nil,
            dispositions: ["attached_pic"],
            startSeconds: 0,
            durationSeconds: 0
        )
        XCTAssertTrue(artwork.isUserFacing)
    }

    func testAudioFrameCountOverridesProgramDurationWhenAVIOMitsStreamDuration() throws {
        let document = try JSONDecoder().decode(ProbeDocument.self, from: Data("""
        {
          "streams": [{
            "index": 1,
            "codec_name": "pcm_s24le",
            "codec_type": "audio",
            "sample_rate": "48000",
            "channels": 2,
            "duration": "170.837504",
            "nb_frames": "8199936"
          }],
          "format": { "format_name": "avi", "duration": "170.837504" }
        }
        """.utf8))
        let stream = try XCTUnwrap(document.streams.first)
        let descriptor = try FFprobeMapping.audioDescriptor(
            stream, duration: 170.837_504
        )
        XCTAssertEqual(descriptor.durationSeconds, 170.832, accuracy: 0.000_001)
    }

    func testCompressedAVIFrameCountDoesNotMasqueradeAsDecodedSampleCount() throws {
        let document = try JSONDecoder().decode(ProbeDocument.self, from: Data("""
        {
          "streams": [{
            "index": 1,
            "codec_name": "mp3",
            "codec_type": "audio",
            "sample_rate": "48000",
            "channels": 2,
            "nb_frames": "8699010"
          }],
          "format": { "format_name": "avi", "duration": "543.752085" }
        }
        """.utf8))
        let stream = try XCTUnwrap(document.streams.first)
        let descriptor = try FFprobeMapping.audioDescriptor(
            stream, duration: 543.752_085
        )
        XCTAssertEqual(descriptor.durationSeconds, 543.752_085, accuracy: 0.000_001)
    }

    func testHEAACRegressionIsInspectedAtPresentedRate() async throws {
        let sample = try MediaTestFixtures.requireHEAAC()
        let document = try await FFprobeClient(
            executableURL: MediaTestRuntime.ffprobeURL
        ).document(sample)
        let audio = try XCTUnwrap(document.streams.first { $0.codecType == "audio" })
        XCTAssertEqual(audio.codecName, "aac")
        XCTAssertEqual(audio.trackID?.value, 1)
        XCTAssertEqual(try sha256(of: sample), "d3db8f50185792e353ebc506bc3d5d86d224872219d8d505b06513c6b622ac6c")

        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let inspection = try await engine.inspect(sample)
        let selected = inspection.media.audioTracks.first?.audioDescriptor
        XCTAssertEqual(selected?.sampleRate, 48_000)
        XCTAssertEqual(selected?.channelCount, 2)
    }

    func testAACPreparationRejectsPresentationShapeChangedSinceInspection() async throws {
        let sample = try MediaTestFixtures.requireHEAAC()
        let decoder = ProbeSequenceAACDecoder(presentations: [
            AACDecodedPresentation(
                sampleRate: 48_000,
                channelCount: 2,
                durationSeconds: 3
            ),
            AACDecodedPresentation(
                sampleRate: 24_000,
                channelCount: 2,
                durationSeconds: 3
            ),
        ])
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL,
            aacDecoder: decoder
        )
        let inspection = try await engine.inspect(sample)
        let info = try inspection.media.mediaInfo(
            selectingAudioStreamIndex: inspection.media.suggestedAudioStreamIndex
        )

        do {
            _ = try await engine.plan(
                inputURL: sample,
                info: info,
                context: inspection.context,
                options: .standard
            )
            XCTFail("AAC preparation accepted a changed presentation shape")
        } catch let error as MediaIOError {
            guard case .readerFailed(let message) = error else {
                return XCTFail("unexpected preparation error: \(error)")
            }
            XCTAssertTrue(message.contains("changed after inspection"))
        }
    }

    func testAACInspectionReportsAppleCodecServiceFailure() async throws {
        let sample = try MediaTestFixtures.requireHEAAC()
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL,
            aacDecoder: FailingAACDecoder()
        )

        do {
            _ = try await engine.inspect(sample)
            XCTFail("AAC inspection ignored an unavailable Apple codec service")
        } catch let error as MediaIOError {
            guard case .invalidAudioFormat(let message) = error else {
                return XCTFail("unexpected inspection error: \(error)")
            }
            XCTAssertTrue(message.contains("Apple AAC codec service unavailable"))
        }
    }

    func testFFprobeTrackIdentifierAcceptsHexadecimalAndDecimalValues() throws {
        struct Record: Decodable {
            let id: ProbeTrackIdentifier
        }
        let decoder = JSONDecoder()
        XCTAssertEqual(
            try decoder.decode(Record.self, from: Data(#"{"id":"0x2a"}"#.utf8)).id.value,
            42
        )
        XCTAssertEqual(
            try decoder.decode(Record.self, from: Data(#"{"id":17}"#.utf8)).id.value,
            17
        )
    }

    func testInspectionRejectsAnExtensionThatDisagreesWithFFprobe() async throws {
        let sample = try MediaTestFixtures.requireHEAAC()
        let disguised = FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechLens-Misnamed-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: disguised) }
        try FileManager.default.copyItem(at: sample, to: disguised)

        do {
            _ = try await UnifiedFFmpegMediaEngine(
                executableURL: MediaTestRuntime.ffmpegURL,
                probeExecutableURL: MediaTestRuntime.ffprobeURL
            ).inspect(disguised)
            XCTFail("inspection accepted an MP4 that was named as WAV")
        } catch let error as MediaIOError {
            guard case .invalidAudioFormat = error else {
                return XCTFail("unexpected inspection error: \(error)")
            }
        }
    }

    private func sha256(of url: URL) throws -> String {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw NSError(domain: "MediaInspectionTests", code: Int(process.terminationStatus))
        }
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8
        ) ?? ""
        return text.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? ""
    }
}

private actor ProbeSequenceAACDecoder: AACPCMDecoder {
    private var presentations: [AACDecodedPresentation]

    init(presentations: [AACDecodedPresentation]) {
        self.presentations = presentations
    }

    func probe(
        sourceURL: URL,
        trackID: Int32
    ) async throws -> AACDecodedPresentation {
        _ = sourceURL
        _ = trackID
        guard !presentations.isEmpty else {
            throw MediaIOError.readerFailed("Apple AAC probe sequence exhausted")
        }
        return presentations.removeFirst()
    }

    nonisolated func open(
        sourceURL: URL,
        trackID: Int32,
        descriptor: AudioStreamDescriptor
    ) async throws -> any NativeRateAudioSource {
        _ = sourceURL
        _ = trackID
        _ = descriptor
        throw MediaIOError.readerFailed("not used by this test")
    }
}

private struct FailingAACDecoder: AACPCMDecoder {
    func probe(
        sourceURL: URL,
        trackID: Int32
    ) async throws -> AACDecodedPresentation {
        _ = sourceURL
        _ = trackID
        throw MediaIOError.readerFailed("Apple AAC codec service unavailable")
    }

    func open(
        sourceURL: URL,
        trackID: Int32,
        descriptor: AudioStreamDescriptor
    ) async throws -> any NativeRateAudioSource {
        _ = sourceURL
        _ = trackID
        _ = descriptor
        throw MediaIOError.readerFailed("Apple AAC codec service unavailable")
    }
}
