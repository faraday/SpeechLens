// SPDX-License-Identifier: Apache-2.0

import TestSupport
import XCTest

final class TestAudioIOTests: XCTestCase {
    func testPlanarInterleavedRoundTrip() throws {
        let channels: [[Float]] = [[1, 2, 3], [4, 5, 6]]
        let contents = try TestAudioContents(planarChannels: channels, sampleRate: 48_000)

        XCTAssertEqual(contents.samples, [1, 4, 2, 5, 3, 6])
        XCTAssertEqual(try contents.planarChannels(), channels)
    }

    func testMalformedInterleavedBufferIsRejected() {
        let contents = TestAudioContents(
            samples: [1, 2, 3],
            sampleRate: 48_000,
            channelCount: 2
        )
        XCTAssertThrowsError(try contents.planarChannels())
    }

    func testDownmixHandlesMonoSilenceAndMultichannel() throws {
        let mono = try TestAudioContents(planarChannels: [[1, -1]], sampleRate: 48_000)
        XCTAssertEqual(mono.downmixedToMonoSamples(), [1, -1])

        let silence = try TestAudioContents(planarChannels: [[], []], sampleRate: 48_000)
        XCTAssertEqual(silence.downmixedToMonoSamples(), [])

        let multichannel = try TestAudioContents(
            planarChannels: [[1, 3], [2, 4], [3, 5]],
            sampleRate: 48_000
        )
        XCTAssertEqual(multichannel.downmixedToMonoSamples(), [2, 4])
    }
}
