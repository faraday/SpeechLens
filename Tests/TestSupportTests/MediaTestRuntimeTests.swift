// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
import XCTest

final class MediaTestRuntimeTests: XCTestCase {
    func testExecutableURLsUseExactOverridesOrBundledDefaults() {
        let bundledRuntime = ModelTestPaths.projectRoot
            .appendingPathComponent(".build/ffmpeg-runtime/installed")
        let environment = ProcessInfo.processInfo.environment
        XCTAssertEqual(
            MediaTestRuntime.ffmpegURL,
            environment["SPEECHLENS_FFMPEG"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? bundledRuntime.appendingPathComponent("ffmpeg")
        )
        XCTAssertEqual(
            MediaTestRuntime.ffprobeURL,
            environment["SPEECHLENS_FFPROBE"]
                .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
                ?? bundledRuntime.appendingPathComponent("ffprobe")
        )
    }

    func testRequiredHEAACFixtureExists() throws {
        let fixture = try MediaTestFixtures.requireHEAAC()
        XCTAssertEqual(fixture.pathExtension, "m4a")
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.path))
    }

}
