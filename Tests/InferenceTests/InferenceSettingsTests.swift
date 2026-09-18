// SPDX-License-Identifier: Apache-2.0

import XCTest
import Inference

final class InferenceSettingsTests: XCTestCase {
    func testAcceptsValidSettings() throws {
        XCTAssertEqual(InferenceSettings.standard.chunkSeconds, 5.0)
        XCTAssertEqual(InferenceSettings.standard.overlapPortion, 0.05)

        let directDefault = try InferenceSettings()
        XCTAssertEqual(directDefault, .standard)

        let noOverlap = try InferenceSettings(chunkSeconds: 1.0, overlapPortion: 0.0)
        XCTAssertEqual(noOverlap.chunkSeconds, 1.0)
        XCTAssertEqual(noOverlap.overlapPortion, 0.0)

        let maxOverlap = try InferenceSettings(chunkSeconds: 60.0, overlapPortion: 0.5)
        XCTAssertEqual(maxOverlap.chunkSeconds, 60.0)
        XCTAssertEqual(maxOverlap.overlapPortion, 0.5)
    }

    func testRejectsInvalidChunkSeconds() {
        assertInvalidChunkSeconds(0.0)
        assertInvalidChunkSeconds(-1.0)
        assertInvalidChunkSeconds(.nan)
        assertInvalidChunkSeconds(.infinity)
    }

    func testRejectsInvalidOverlapPortion() {
        assertInvalidOverlapPortion(-0.01)
        assertInvalidOverlapPortion(0.51)
        assertInvalidOverlapPortion(.nan)
        assertInvalidOverlapPortion(.infinity)
    }

    func testCopyHelpersValidateUpdatedValues() throws {
        let settings = try InferenceSettings(chunkSeconds: 30.0, overlapPortion: 0.1)

        XCTAssertEqual(try settings.with(chunkSeconds: 5.0).chunkSeconds, 5.0)
        XCTAssertEqual(try settings.with(overlapPortion: 0.5).overlapPortion, 0.5)

        XCTAssertThrowsError(try settings.with(chunkSeconds: 0.0)) { error in
            XCTAssertEqual(error as? InferenceSettingsError, .invalidChunkSeconds)
        }
        XCTAssertThrowsError(try settings.with(overlapPortion: 0.75)) { error in
            XCTAssertEqual(error as? InferenceSettingsError, .invalidOverlapPortion)
        }
    }

    func testCodableRoundTripValidatesValues() throws {
        let settings = try InferenceSettings(chunkSeconds: 12.0, overlapPortion: 0.25)
        let data = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(InferenceSettings.self, from: data)

        XCTAssertEqual(decoded, settings)
    }

    func testDecodingRejectsInvalidValues() {
        let invalidChunk = Data(#"{"chunkSeconds":0,"overlapPortion":0.1}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(InferenceSettings.self, from: invalidChunk)) { error in
            XCTAssertEqual(error as? InferenceSettingsError, .invalidChunkSeconds)
        }

        let invalidOverlap = Data(#"{"chunkSeconds":30,"overlapPortion":0.75}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(InferenceSettings.self, from: invalidOverlap)) { error in
            XCTAssertEqual(error as? InferenceSettingsError, .invalidOverlapPortion)
        }
    }

    func testLocalizedErrorsMentionOffendingFields() {
        XCTAssertTrue(
            InferenceSettingsError.invalidChunkSeconds.localizedDescription.contains("chunkSeconds")
        )
        XCTAssertTrue(
            InferenceSettingsError.invalidOverlapPortion.localizedDescription.contains("overlapPortion")
        )
    }

    private func assertInvalidChunkSeconds(
        _ value: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try InferenceSettings(chunkSeconds: value, overlapPortion: 0.0),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? InferenceSettingsError, .invalidChunkSeconds, file: file, line: line)
        }
    }

    private func assertInvalidOverlapPortion(
        _ value: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertThrowsError(
            try InferenceSettings(chunkSeconds: 30.0, overlapPortion: value),
            file: file,
            line: line
        ) { error in
            XCTAssertEqual(error as? InferenceSettingsError, .invalidOverlapPortion, file: file, line: line)
        }
    }
}
