// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
import XCTest

final class BundledMediaRuntimeTests: XCTestCase {
    func testBundledRuntimeContainsRequiredEncoders() throws {
        let executable = MediaTestRuntime.ffmpegURL
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["-hide_banner", "-encoders"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let text = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        XCTAssertEqual(process.terminationStatus, 0)
        let encoders = componentNames(text)
        XCTAssertTrue(encoders.contains("aac_at"))
        XCTAssertFalse(encoders.contains("aac"))
        XCTAssertTrue(encoders.contains("alac"))
        XCTAssertTrue(encoders.contains("libmp3lame"))
        XCTAssertTrue(encoders.contains("flac"))
        XCTAssertTrue(encoders.contains("pcm_f32le"))

        let decoderOutput = Pipe()
        let decoderProcess = Process()
        decoderProcess.executableURL = executable
        decoderProcess.arguments = ["-hide_banner", "-decoders"]
        decoderProcess.standardOutput = decoderOutput
        decoderProcess.standardError = FileHandle.nullDevice
        try decoderProcess.run()
        decoderProcess.waitUntilExit()
        XCTAssertEqual(decoderProcess.terminationStatus, 0)
        let decoders = componentNames(String(
            data: decoderOutput.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? "")
        for forbidden in ["aac", "aac_fixed", "aac_latm", "aac_at"] {
            XCTAssertFalse(decoders.contains(forbidden))
        }
    }

    private func componentNames(_ output: String) -> Set<String> {
        Set(output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(whereSeparator: \.isWhitespace)
            guard fields.count >= 2, fields[0].count == 6 else { return nil }
            return String(fields[1])
        })
    }
}
