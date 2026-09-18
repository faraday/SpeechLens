// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct RealAudioFixture: Sendable, Equatable {
    public let sampleRate: Int
    public let name: String
    public let directoryURL: URL

    public var label: String {
        "\(sampleRate)_\(name)"
    }

    public var inputURL: URL {
        directoryURL.appendingPathComponent("input.wav")
    }

    public var expectedURL: URL {
        directoryURL.appendingPathComponent("expected.wav")
    }
}

public enum RealFixtureCatalog {
    public static let requiredSampleRates: Set<Int> = [16_000, 44_100, 48_000]

    public static var realFixturesRoot: URL {
        ModelTestPaths.projectRoot.appendingPathComponent("Tests/Fixtures/Real")
    }

    public static func discoverFixtures() throws -> [RealAudioFixture] {
        try discoverFixtures(at: realFixturesRoot)
    }

    public static func discoverFixtures(at root: URL) throws -> [RealAudioFixture] {
        let fm = FileManager.default
        guard fm.fileExists(atPath: root.path) else {
            throw RealFixtureCatalogError.missingDirectory(root.path)
        }

        let sampleRateDirs = try fm.contentsOfDirectory(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: .skipsHiddenFiles
        )

        var fixtures: [RealAudioFixture] = []
        for sampleRateDir in sampleRateDirs where sampleRateDir.hasDirectoryPath {
            guard let sampleRate = Int(sampleRateDir.lastPathComponent) else {
                continue
            }

            let fixtureDirs = try fm.contentsOfDirectory(
                at: sampleRateDir,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: .skipsHiddenFiles
            )

            for fixtureDir in fixtureDirs where fixtureDir.hasDirectoryPath {
                let fixture = RealAudioFixture(
                    sampleRate: sampleRate,
                    name: fixtureDir.lastPathComponent,
                    directoryURL: fixtureDir
                )
                if hasRequiredFiles(for: fixture) {
                    fixtures.append(fixture)
                }
            }
        }

        return fixtures.sorted {
            if $0.sampleRate == $1.sampleRate {
                return $0.name < $1.name
            }
            return $0.sampleRate < $1.sampleRate
        }
    }

    public static func requireFixtures() throws -> [RealAudioFixture] {
        try requireFixtures(at: realFixturesRoot)
    }

    public static func requireFixtures(at root: URL) throws -> [RealAudioFixture] {
        let fixtures = try discoverFixtures(at: root)
        let availableSampleRates = Set(fixtures.map(\.sampleRate))
        let missingSampleRates = requiredSampleRates
            .subtracting(availableSampleRates)
            .sorted()
        guard missingSampleRates.isEmpty else {
            throw RealFixtureCatalogError.missingRequiredSampleRates(
                missingSampleRates,
                root.path
            )
        }
        return fixtures
    }

    private static func hasRequiredFiles(for fixture: RealAudioFixture) -> Bool {
        let fm = FileManager.default
        return fm.fileExists(atPath: fixture.inputURL.path)
            && fm.fileExists(atPath: fixture.expectedURL.path)
    }
}

public enum RealFixtureCatalogError: Error, CustomStringConvertible, Equatable {
    case missingDirectory(String)
    case missingRequiredSampleRates([Int], String)

    public var description: String {
        switch self {
        case .missingDirectory(let path):
            return "Real audio fixture directory is missing: \(path)"
        case .missingRequiredSampleRates(let sampleRates, let path):
            let rates = sampleRates.map(String.init).joined(separator: ", ")
            return """
            Required real audio fixture sample rates are missing under \(path): \(rates) Hz.
            Each required rate needs at least one fixture with input.wav and expected.wav.
            """
        }
    }
}
