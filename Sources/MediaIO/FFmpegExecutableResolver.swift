// SPDX-License-Identifier: Apache-2.0

import Foundation

enum FFmpegExecutableResolver {
    static let environmentKey = "SPEECHLENS_FFMPEG"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        processExecutablePath: String? = CommandLine.arguments.first,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) throws -> URL {
        try HelperExecutableResolver.resolve(
            name: "ffmpeg",
            environmentKey: environmentKey,
            environment: environment,
            bundleExecutableURL: bundleExecutableURL,
            processExecutablePath: processExecutablePath,
            additionalCandidates: [],
            isExecutable: isExecutable
        )
    }
}

enum FFprobeExecutableResolver {
    static let environmentKey = "SPEECHLENS_FFPROBE"

    static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        bundleExecutableURL: URL? = Bundle.main.executableURL,
        processExecutablePath: String? = CommandLine.arguments.first,
        ffmpegExecutableURL: URL? = nil,
        isExecutable: (String) -> Bool = FileManager.default.isExecutableFile(atPath:)
    ) throws -> URL {
        let sibling = ffmpegExecutableURL?.deletingLastPathComponent()
            .appendingPathComponent("ffprobe")
        return try HelperExecutableResolver.resolve(
            name: "ffprobe",
            environmentKey: environmentKey,
            environment: environment,
            bundleExecutableURL: bundleExecutableURL,
            processExecutablePath: processExecutablePath,
            additionalCandidates: sibling.map { [$0] } ?? [],
            isExecutable: isExecutable
        )
    }
}

private enum HelperExecutableResolver {
    static func resolve(
        name: String,
        environmentKey: String,
        environment: [String: String],
        bundleExecutableURL: URL?,
        processExecutablePath: String?,
        additionalCandidates: [URL],
        isExecutable: (String) -> Bool
    ) throws -> URL {
        var candidates = [URL]()
        if let override = environment[environmentKey], !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        candidates += additionalCandidates
        if let bundleExecutableURL {
            candidates.append(
                bundleExecutableURL.deletingLastPathComponent()
                    .appendingPathComponent(name)
            )
        }
        if let processExecutablePath, !processExecutablePath.isEmpty {
            candidates.append(
                URL(fileURLWithPath: processExecutablePath)
                    .standardizedFileURL
                    .deletingLastPathComponent()
                    .appendingPathComponent(name)
            )
        }
        if let candidate = candidates.first(where: { isExecutable($0.path) }) {
            return candidate
        }
        throw MediaIOError.ffmpegUnavailable(
            "expected executable helpers named ffmpeg and ffprobe beside SpeechLens"
        )
    }
}
