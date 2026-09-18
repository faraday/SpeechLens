// SPDX-License-Identifier: Apache-2.0

import XCTest
import AudioIO

final class AudioIOTests: XCTestCase {
    func testPlanarStreamBlockRejectsEmptyAndUnequalChannels() {
        XCTAssertThrowsError(try PlanarAudioBlock(channels: []))
        XCTAssertThrowsError(try PlanarAudioBlock(channels: [[]]))
        XCTAssertThrowsError(try PlanarAudioBlock(channels: [[1, 2], [3]]))
    }

    func testStreamingRoundTripPreservesMonoStereoAndFourChannelBlocks() throws {
        for channelCount in [1, 2, 4] {
            let channels = (0..<channelCount).map { channel in
                (0..<11).map { frame in Float(channel * 100 + frame) / 100 }
            }
            let url = temporaryURL(name: "stream-\(channelCount).wav")
            defer { try? FileManager.default.removeItem(at: url) }

            let writer = try AudioFileStreamWriter(
                url: url,
                sampleRate: 44_100,
                channelCount: channelCount
            )
            try writer.append(PlanarAudioBlock(channels: channels.map { Array($0[0..<4]) }))
            try writer.append(PlanarAudioBlock(channels: channels.map { Array($0[4..<11]) }))
            try writer.close()

            let reader = try AudioFileStreamReader(url: url)
            defer { reader.close() }
            XCTAssertEqual(reader.info.sampleRate, 44_100)
            XCTAssertEqual(reader.info.channelCount, channelCount)
            XCTAssertEqual(reader.info.frameCount, 11)

            var restored = Array(repeating: [Float](), count: channelCount)
            var blockSizes = [Int]()
            while let block = try reader.read(maxFrameCount: 3) {
                blockSizes.append(block.frameCount)
                for channel in 0..<channelCount {
                    restored[channel].append(contentsOf: block.channels[channel])
                }
            }
            XCTAssertEqual(blockSizes, [3, 3, 3, 2])
            for channel in 0..<channelCount {
                XCTAssertEqual(restored[channel], channels[channel])
            }
            XCTAssertNil(try reader.read(maxFrameCount: 3))
        }
    }

    func testStreamingReaderRejectsInvalidBlockSize() throws {
        let fixture = projectRoot.appendingPathComponent(
            "Tests/Fixtures/Synthetic/sine_plus_noise_44100.wav"
        )
        let reader = try AudioFileStreamReader(url: fixture)
        defer { reader.close() }
        XCTAssertThrowsError(try reader.read(maxFrameCount: 0))
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func temporaryURL(name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("SpeechLens-AudioIOTests-\(UUID().uuidString)-\(name)")
    }
}
