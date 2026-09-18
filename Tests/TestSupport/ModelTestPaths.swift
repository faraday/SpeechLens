// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum ModelTestPaths {
    public static let convertedWeightsEnvironmentKey = "SPEECHLENS_TEST_WEIGHTS"

    public static func requireConvertedWeights(
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> URL {
        if let url = convertedWeightsURL() {
            return url
        }

        throw ModelTestPathError.missingConvertedWeights(
            environmentKey: convertedWeightsEnvironmentKey,
            searchedPaths: convertedWeightCandidates().map(\.path),
            file: String(describing: file),
            line: line
        )
    }

    public static func convertedWeightsURL() -> URL? {
        let fm = FileManager.default
        for url in convertedWeightCandidates() where fm.fileExists(atPath: url.path) {
            return url
        }
        return nil
    }

    public static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    public static var installedWeightsURL: URL {
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support", isDirectory: true)

        return applicationSupport
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent("model_mlx.safetensors", isDirectory: false)
    }

    private static func convertedWeightCandidates() -> [URL] {
        var candidates: [URL] = []
        if let path = ProcessInfo.processInfo.environment[convertedWeightsEnvironmentKey],
           !path.isEmpty {
            candidates.append(URL(fileURLWithPath: path))
        }

        candidates.append(installedWeightsURL)
        return candidates
    }
}

public enum ModelTestPathError: Error, CustomStringConvertible {
    case missingConvertedWeights(
        environmentKey: String,
        searchedPaths: [String],
        file: String,
        line: UInt
    )

    public var description: String {
        switch self {
        case let .missingConvertedWeights(environmentKey, searchedPaths, file, line):
            let paths = searchedPaths.map { "  - \($0)" }.joined(separator: "\n")
            return """
            Converted MLX weights not found at \(file):\(line).
            Set \(environmentKey) to model_mlx.safetensors.
            Searched:
            \(paths)
            """
        }
    }
}
