// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum MediaTestRuntime {
    public static var ffmpegURL: URL {
        environmentOverride("SPEECHLENS_FFMPEG")
            ?? bundledRuntimeDirectory.appendingPathComponent("ffmpeg")
    }

    public static var ffprobeURL: URL {
        environmentOverride("SPEECHLENS_FFPROBE")
            ?? bundledRuntimeDirectory.appendingPathComponent("ffprobe")
    }

    @discardableResult
    public static func runFFmpeg(_ arguments: [String]) throws -> String {
        let process = Process()
        let output = Pipe()
        let error = Pipe()
        process.executableURL = ffmpegURL
        process.arguments = arguments
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output
        process.standardError = error
        try process.run()
        process.waitUntilExit()
        let stdout = String(
            data: output.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8
        ) ?? ""
        guard process.terminationStatus == 0 else {
            throw NSError(
                domain: "MediaTestRuntime",
                code: Int(process.terminationStatus),
                userInfo: [
                    NSLocalizedDescriptionKey: String(
                        data: error.fileHandleForReading.readDataToEndOfFile(),
                        encoding: .utf8
                    ) ?? ""
                ]
            )
        }
        return stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static var bundledRuntimeDirectory: URL {
        ModelTestPaths.projectRoot
            .appendingPathComponent(".build/ffmpeg-runtime/installed")
    }

    private static func environmentOverride(_ key: String) -> URL? {
        if let override = ProcessInfo.processInfo.environment[key],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return nil
    }
}

public enum MediaTestFixtures {
    public static func requireHEAAC() throws -> URL {
        let url = ModelTestPaths.projectRoot.appendingPathComponent(
            "Tests/Fixtures/Codec/heaac-stereo-48000/"
                + "heaac-stereo-48000.m4a"
        )
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw NSError(
                domain: "MediaTestFixtures",
                code: 1,
                userInfo: [
                    NSLocalizedDescriptionKey:
                        "CI-owned HE-AAC fixture is missing: \(url.path)"
                ]
            )
        }
        return url
    }
}
