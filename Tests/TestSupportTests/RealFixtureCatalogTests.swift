// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
import XCTest

final class RealFixtureCatalogTests: XCTestCase {
    func testCommittedCatalogContainsEveryRequiredSampleRate() throws {
        let fixtures = try RealFixtureCatalog.requireFixtures()

        XCTAssertTrue(
            RealFixtureCatalog.requiredSampleRates.isSubset(
                of: Set(fixtures.map(\.sampleRate))
            )
        )
    }

    func testMissingRequiredSampleRateIsReportedExactly() throws {
        let root = try temporaryFixtureRoot()
        try makeFixture(sampleRate: 16_000, name: "sixteen", under: root)
        try makeFixture(sampleRate: 48_000, name: "forty-eight", under: root)

        XCTAssertThrowsError(try RealFixtureCatalog.requireFixtures(at: root)) {
            XCTAssertEqual(
                $0 as? RealFixtureCatalogError,
                .missingRequiredSampleRates([44_100], root.path)
            )
        }
    }

    func testAdditionalCompleteFixturesRemainDiscoverable() throws {
        let root = try temporaryFixtureRoot()
        for sampleRate in [16_000, 44_100, 48_000, 96_000] {
            try makeFixture(
                sampleRate: sampleRate,
                name: "fixture-\(sampleRate)",
                under: root
            )
        }

        let fixtures = try RealFixtureCatalog.requireFixtures(at: root)

        XCTAssertEqual(fixtures.map(\.sampleRate), [16_000, 44_100, 48_000, 96_000])
    }

    private func temporaryFixtureRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "SpeechLens-RealFixtureCatalogTests-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false
        )
        addTeardownBlock {
            try? FileManager.default.removeItem(at: root)
        }
        return root
    }

    private func makeFixture(
        sampleRate: Int,
        name: String,
        under root: URL
    ) throws {
        let directory = root
            .appendingPathComponent(String(sampleRate), isDirectory: true)
            .appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        try Data().write(to: directory.appendingPathComponent("input.wav"))
        try Data().write(to: directory.appendingPathComponent("expected.wav"))
    }
}
