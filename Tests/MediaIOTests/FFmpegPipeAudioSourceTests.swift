// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import TestSupport
import XCTest
@testable import MediaIO

final class FFmpegPipeAudioSourceTests: XCTestCase {
    func testTimestampGapIsRenderedAsDigitalSilenceWithoutRateChange() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeechLens-Timeline-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        let raw = directory.appendingPathComponent("continuous.f32le")
        let samples = [Float](repeating: 0.5, count: 9_600)
        try samples.withUnsafeBytes {
            try Data($0).write(to: raw, options: .atomic)
        }
        let media = directory.appendingPathComponent("gap.mkv")
        try MediaTestRuntime.runFFmpeg([
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-f", "f32le", "-ar", "48000", "-ac", "1", "-i", raw.path,
            "-af", "aselect=not(between(t\\,0.05\\,0.10))",
            "-c:a", "pcm_f32le", media.path,
        ])
        let descriptor = AudioStreamDescriptor(
            sampleRate: 48_000,
            channelCount: 1,
            validFrameCount: nil,
            presentationStartSeconds: 0,
            durationSeconds: 0.2,
            channelLayout: AudioChannelLayoutDescriptor(
                rawData: nil, inferred: true, ffmpegName: "mono"
            ),
            codec: AudioCodecDescriptor(
                formatID: kAudioFormatLinearPCM,
                fourCC: "pcm_f32le",
                bitsPerChannel: 32
            ),
            estimatedBitRate: nil
        )
        let source = try FFmpegPipeAudioSource(
            executableURL: MediaTestRuntime.ffmpegURL,
            sourceURL: media,
            streamIndex: 0,
            descriptor: descriptor
        )
        defer { source.close() }
        var decoded = [Float]()
        while let block = try source.read(maxFrameCount: 1_024) {
            decoded += block.audio.channels[0]
        }
        XCTAssertEqual(descriptor.sampleRate, 48_000)
        XCTAssertLessThanOrEqual(abs(decoded.count - 9_600), 1_024)
        guard decoded.count >= 4_500 else {
            return XCTFail("decoder did not render the complete program timeline")
        }
        XCTAssertGreaterThan(decoded.prefix(1_500).map(abs).max() ?? 0, 0.4)
        XCTAssertGreaterThan(decoded.suffix(1_500).map(abs).max() ?? 0, 0.4)
        var longestSilence = 0
        var currentSilence = 0
        for sample in decoded {
            if abs(sample) < 0.000_001 {
                currentSilence += 1
                longestSilence = max(longestSilence, currentSilence)
            } else {
                currentSilence = 0
            }
        }
        XCTAssertGreaterThanOrEqual(longestSilence, 1_500)
    }
}
