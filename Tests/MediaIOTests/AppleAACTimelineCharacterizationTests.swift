// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioToolbox
import CoreMedia
import Foundation
import TestSupport
import XCTest
@testable import MediaIO

final class AppleAACTimelineCharacterizationTests: XCTestCase {
    private let sampleRate = 48_000
    private let channelCount = 2
    private let codecFrameTolerance = 1_024

    func testHEAACRawPaddingIsSilentBeyondApplePresentation() async throws {
        let fixture = try MediaTestFixtures.requireHEAAC()
        let raw = try await characterizeAppleDecode(fixture)

        XCTAssertEqual(raw.sampleRate, sampleRate)
        XCTAssertEqual(raw.channelCount, channelCount)
        XCTAssertEqual(raw.presentationFrameLimit, 144_000)
        XCTAssertGreaterThanOrEqual(raw.frameCount, raw.presentationFrameLimit)
        XCTAssertGreaterThan(raw.timing.sampleCount, 0)
        XCTAssertTrue(raw.timing.allFinite)
        XCTAssertTrue(raw.timing.hasCompleteRange)
        XCTAssertGreaterThan(raw.timing.accumulatedOutputDurationSeconds, 0)
        XCTAssertTrue(raw.beforeBoundaryRMS.allSatisfy { $0 > 0.001 })
        if raw.frameCount > raw.presentationFrameLimit {
            XCTAssertTrue(
                raw.afterBoundaryRMS.allSatisfy { $0 < 0.000_1 },
                "AVAssetReader emitted non-silent HE-AAC data beyond "
                    + "the declared presentation"
            )
        }

        let decoded = try await MediaIOTestHarness.captureSelectedAudio(
            fixture, maxFrameCount: 777
        )
        XCTAssertEqual(decoded.frameCount, raw.presentationFrameLimit)
        assertReadContract(decoded, maxFrameCount: 777)
        XCTAssertTrue(decoded.repeatedEOF)
        XCTAssertTrue(decoded.postCloseEOF)
        let tailRMS = try XCTUnwrap(
            decoded.rootMeanSquare(frames: 140_000..<143_500, channel: 0),
            "HE-AAC tail RMS window was outside captured PCM"
        )
        XCTAssertGreaterThan(
            tailRMS,
            0.02,
            "the presentation cap removed meaningful HE-AAC tail content"
        )
    }

    func testHEAACEditListsStayWithinApplePresentationTimeline() async throws {
        let directory = try MediaIOTestHarness.temporaryDirectory(
            prefix: "SpeechLens-AAC-Edits"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let fixture = try MediaTestFixtures.requireHEAAC()
        let trimmed = directory.appendingPathComponent("trimmed.m4a")
        let offset = directory.appendingPathComponent("offset.m4a")

        try MediaTestRuntime.runFFmpeg([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-ss", "0.25", "-i", fixture.path,
            "-map", "0:a:0", "-c", "copy", trimmed.path,
        ])
        try MediaTestRuntime.runFFmpeg([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-itsoffset", "0.25", "-i", fixture.path,
            "-map", "0:a:0", "-c", "copy", offset.path,
        ])

        let trimmedRaw = try await characterizeAppleDecode(trimmed)
        XCTAssertTrue(trimmedRaw.hasSourceTrim)
        XCTAssertEqual(trimmedRaw.presentationFrameLimit, 132_000)
        let offsetRaw = try await characterizeAppleDecode(offset)
        XCTAssertTrue(offsetRaw.beginsWithEmptyEdit)
        XCTAssertEqual(offsetRaw.presentationFrameLimit, 156_000)

        for (url, raw) in [(trimmed, trimmedRaw), (offset, offsetRaw)] {
            let decoded = try await MediaIOTestHarness.captureSelectedAudio(
                url, maxFrameCount: 333
            )
            assertReadContract(decoded, maxFrameCount: 333)
            XCTAssertLessThanOrEqual(decoded.frameCount, raw.presentationFrameLimit)
            XCTAssertLessThanOrEqual(
                raw.presentationFrameLimit - decoded.frameCount,
                codecFrameTolerance,
                "Apple AAC EOF differed from the presentation by more than "
                    + "one codec frame for \(url.lastPathComponent)"
            )
        }
    }

    func testAACLCBoundaryMarkersRemainInsidePresentation() async throws {
        let directory = try MediaIOTestHarness.temporaryDirectory(
            prefix: "SpeechLens-AAC-LC"
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let mediaURL = try makeAACLCMarkerFixture(in: directory)
        let authoredFrameCount = sampleRate * 2

        let raw = try await characterizeAppleDecode(mediaURL)
        let decoded = try await MediaIOTestHarness.captureSelectedAudio(
            mediaURL, maxFrameCount: 509
        )
        XCTAssertGreaterThanOrEqual(raw.presentationFrameLimit, authoredFrameCount)
        XCTAssertLessThanOrEqual(
            raw.presentationFrameLimit - authoredFrameCount,
            codecFrameTolerance
        )
        assertReadContract(decoded, maxFrameCount: 509)
        XCTAssertLessThanOrEqual(decoded.frameCount, raw.presentationFrameLimit)
        XCTAssertLessThanOrEqual(
            raw.presentationFrameLimit - decoded.frameCount,
            codecFrameTolerance
        )
        let leadingRMS = try XCTUnwrap(
            decoded.rootMeanSquare(frames: 512..<3_584, channel: 0),
            "AAC-LC leading marker RMS window was outside captured PCM"
        )
        XCTAssertGreaterThan(
            leadingRMS,
            0.05,
            "AAC-LC leading marker was lost"
        )
        let trailingRMS = try XCTUnwrap(
            decoded.rootMeanSquare(
                frames: (decoded.frameCount - 3_584)..<(decoded.frameCount - 512),
                channel: 1
            ),
            "AAC-LC trailing marker RMS window was outside captured PCM"
        )
        XCTAssertGreaterThan(
            trailingRMS,
            0.05,
            "AAC-LC trailing marker was lost"
        )
    }

    private func characterizeAppleDecode(
        _ url: URL
    ) async throws -> AppleDecodeCharacterization {
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        let track = try XCTUnwrap(tracks.first)
        let timeRange = try await track.load(.timeRange)
        let segments = try await track.load(.segments)
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaIOError.readerFailed("test AVAssetReader rejected AAC")
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaIOError.readerFailed(
                reader.error?.localizedDescription
                    ?? "test AVAssetReader could not start"
            )
        }
        defer {
            if reader.status == .reading { reader.cancelReading() }
        }

        var rate: Int?
        var channels: Int?
        var frameCount = 0
        var beforePower = [Double]()
        var afterPower = [Double]()
        var beforeFrames = 0
        var afterFrames = 0
        var timing = SampleTimingSummary()
        while let sample = output.copyNextSampleBuffer() {
            let shape = try AppleAACPCMDecoder.pcmShape(sample)
            if let rate, let channels {
                guard rate == shape.sampleRate,
                      channels == shape.channelCount else {
                    throw MediaIOError.readerFailed(
                        "test AVAssetReader changed AAC presentation shape"
                    )
                }
            } else {
                rate = shape.sampleRate
                channels = shape.channelCount
                beforePower = [Double](repeating: 0, count: shape.channelCount)
                afterPower = [Double](repeating: 0, count: shape.channelCount)
            }
            timing.record(sample)
            let samples = try AppleAACPCMDecoder.interleavedSamples(
                sample,
                channelCount: shape.channelCount
            )
            let limit = Int(
                (timeRange.duration.seconds * Double(shape.sampleRate)).rounded()
            )
            let sampleFrameCount = samples.count / shape.channelCount
            for frame in 0..<sampleFrameCount {
                let beforeBoundary = frameCount + frame < limit
                for channel in 0..<shape.channelCount {
                    let value = Double(
                        samples[frame * shape.channelCount + channel]
                    )
                    if beforeBoundary {
                        beforePower[channel] += value * value
                    } else {
                        afterPower[channel] += value * value
                    }
                }
                if beforeBoundary { beforeFrames += 1 } else { afterFrames += 1 }
            }
            frameCount += sampleFrameCount
        }
        if reader.status == .failed {
            throw MediaIOError.readerFailed(
                reader.error?.localizedDescription
                    ?? "test AVAssetReader AAC decode failed"
            )
        }
        let decodedRate = try XCTUnwrap(rate)
        let decodedChannels = try XCTUnwrap(channels)
        return AppleDecodeCharacterization(
            sampleRate: decodedRate,
            channelCount: decodedChannels,
            presentationFrameLimit: Int(
                (timeRange.duration.seconds * Double(decodedRate)).rounded()
            ),
            frameCount: frameCount,
            timing: timing,
            hasSourceTrim: segments.contains {
                !$0.isEmpty && $0.timeMapping.source.start.seconds > 0
            },
            beginsWithEmptyEdit: segments.first?.isEmpty == true,
            beforeBoundaryRMS: rootMeanSquares(beforePower, beforeFrames),
            afterBoundaryRMS: rootMeanSquares(afterPower, afterFrames)
        )
    }

    private func makeAACLCMarkerFixture(in directory: URL) throws -> URL {
        let rawURL = directory.appendingPathComponent("markers.f32le")
        let mediaURL = directory.appendingPathComponent("markers.m4a")
        let frameCount = sampleRate * 2
        var samples = [Float]()
        samples.reserveCapacity(frameCount * channelCount)
        for frame in 0..<frameCount {
            let time = Double(frame) / Double(sampleRate)
            let isLeading = frame < 4_096
            let isTrailing = frame >= frameCount - 4_096
            let left = isLeading
                ? 0.36 * sin(2 * .pi * 997 * time)
                : isTrailing ? 0.31 * sin(2 * .pi * 431 * time) : 0
            let right = isLeading
                ? -0.32 * sin(2 * .pi * 613 * time)
                : isTrailing ? -0.34 * sin(2 * .pi * 887 * time) : 0
            samples.append(Float(left))
            samples.append(Float(right))
        }
        try samples.withUnsafeBytes {
            try Data($0).write(to: rawURL, options: .atomic)
        }
        try MediaTestRuntime.runFFmpeg([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "f32le", "-ar", "48000", "-ac", "2", "-i", rawURL.path,
            "-c:a", "aac_at", "-aac_at_mode", "abr", "-b:a", "128k",
            "-movflags", "+faststart", mediaURL.path,
        ])
        return mediaURL
    }

    private func assertReadContract(
        _ capture: MediaAudioCapture,
        maxFrameCount: Int
    ) {
        XCTAssertEqual(capture.sampleRate, sampleRate)
        XCTAssertEqual(capture.channelCount, channelCount)
        XCTAssertEqual(capture.firstPresentationFrame, 0)
        XCTAssertTrue(capture.isContiguousFromZero)
        XCTAssertLessThanOrEqual(capture.largestBlock, maxFrameCount)
    }

    private func rootMeanSquares(
        _ powers: [Double],
        _ frameCount: Int
    ) -> [Double] {
        guard frameCount > 0 else {
            return [Double](repeating: 0, count: powers.count)
        }
        return powers.map { sqrt($0 / Double(frameCount)) }
    }
}

private struct SampleTimingSummary {
    private(set) var sampleCount = 0
    private(set) var allFinite = true
    private(set) var firstRawPresentationSeconds: Double?
    private(set) var lastRawPresentationSeconds: Double?
    private(set) var firstOutputPresentationSeconds: Double?
    private(set) var lastOutputPresentationSeconds: Double?
    private(set) var accumulatedOutputDurationSeconds = 0.0

    var hasCompleteRange: Bool {
        firstRawPresentationSeconds != nil
            && lastRawPresentationSeconds != nil
            && firstOutputPresentationSeconds != nil
            && lastOutputPresentationSeconds != nil
    }

    mutating func record(_ sample: CMSampleBuffer) {
        let raw = CMSampleBufferGetPresentationTimeStamp(sample).seconds
        let output = CMSampleBufferGetOutputPresentationTimeStamp(sample).seconds
        let duration = CMSampleBufferGetOutputDuration(sample).seconds
        sampleCount += 1
        allFinite = allFinite
            && raw.isFinite && output.isFinite && duration.isFinite
            && CMSampleBufferGetNumSamples(sample) > 0
        firstRawPresentationSeconds = firstRawPresentationSeconds ?? raw
        firstOutputPresentationSeconds =
            firstOutputPresentationSeconds ?? output
        lastRawPresentationSeconds = raw
        lastOutputPresentationSeconds = output
        accumulatedOutputDurationSeconds += duration
    }
}

private struct AppleDecodeCharacterization {
    let sampleRate: Int
    let channelCount: Int
    let presentationFrameLimit: Int
    let frameCount: Int
    let timing: SampleTimingSummary
    let hasSourceTrim: Bool
    let beginsWithEmptyEdit: Bool
    let beforeBoundaryRMS: [Double]
    let afterBoundaryRMS: [Double]
}
