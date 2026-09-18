// SPDX-License-Identifier: Apache-2.0

import XCTest

final class MediaAudioCaptureTests: XCTestCase {
    func testRootMeanSquareRejectsInvalidWindowsAndChannels() throws {
        let capture = MediaAudioCapture(
            sampleRate: 48_000,
            channelCount: 1,
            channels: [[0, 1, -1, 0]],
            blocks: [MediaAudioBlockCapture(presentationFrame: 0, frameCount: 4)],
            repeatedEOF: true,
            postCloseEOF: true
        )

        XCTAssertEqual(
            try XCTUnwrap(capture.rootMeanSquare(frames: 0..<4, channel: 0)),
            sqrt(0.5),
            accuracy: 0.000_001
        )
        XCTAssertNil(capture.rootMeanSquare(frames: -1..<1, channel: 0))
        XCTAssertNil(capture.rootMeanSquare(frames: 0..<5, channel: 0))
        XCTAssertNil(capture.rootMeanSquare(frames: 2..<2, channel: 0))
        XCTAssertNil(capture.rootMeanSquare(frames: 0..<1, channel: 1))
    }
}
