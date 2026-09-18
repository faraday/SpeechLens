// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import App

@MainActor
final class ProcessingProfileTests: XCTestCase {
    func testFirstRunUsesFastProfile() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )

        XCTAssertEqual(app.processingProfile, .fast)
        XCTAssertEqual(app.settings.chunkSeconds, 5)
        XCTAssertEqual(app.settings.overlapPortion, 0.05)
    }

    func testInvalidSavedProfileFallsBackToFast() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        defaults.set("unknown", forKey: "processingProfile")

        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )

        XCTAssertEqual(app.processingProfile, .fast)
        XCTAssertEqual(app.settings, .standard)
    }

    func testNamedProfilesApplyTheirFixedSettings() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )

        app.selectProcessingProfile(.balanced)
        XCTAssertEqual(app.settings.chunkSeconds, 10)
        XCTAssertEqual(app.settings.overlapPortion, 0.05)

        app.selectProcessingProfile(.extended)
        XCTAssertEqual(app.settings.chunkSeconds, 30)
        XCTAssertEqual(app.settings.overlapPortion, 0.05)

        app.selectProcessingProfile(.fast)
        XCTAssertEqual(app.settings.chunkSeconds, 5)
        XCTAssertEqual(app.settings.overlapPortion, 0.05)
    }

    func testSelectedProfilePersistsAcrossAppStateInstances() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )
        app.selectProcessingProfile(.extended)

        let restored = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )

        XCTAssertEqual(restored.processingProfile, .extended)
        XCTAssertEqual(restored.settings.chunkSeconds, 30)
        XCTAssertEqual(restored.settings.overlapPortion, 0.05)
    }

    func testFirstCustomSelectionStartsFromFast() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )
        app.selectProcessingProfile(.custom)

        XCTAssertEqual(app.processingProfile, .custom)
        XCTAssertEqual(app.settings.chunkSeconds, 5)
        XCTAssertEqual(app.settings.overlapPortion, 0.05)
    }

    func testCustomSettingsPersistAndRemainCustomWhenMatchingPreset() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )
        app.selectProcessingProfile(.custom)
        app.updateChunkSeconds(10)
        app.updateOverlapPortion(0.05)

        XCTAssertEqual(app.processingProfile, .custom)

        let restored = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )
        XCTAssertEqual(restored.processingProfile, .custom)
        XCTAssertEqual(restored.settings.chunkSeconds, 10)
        XCTAssertEqual(restored.settings.overlapPortion, 0.05)
    }

    func testCustomSettingsAreRestoredAfterSelectingNamedProfile() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )
        app.selectProcessingProfile(.custom)
        app.updateChunkSeconds(17)
        app.updateOverlapPortion(0.15)

        app.selectProcessingProfile(.balanced)
        app.selectProcessingProfile(.custom)

        XCTAssertEqual(app.settings.chunkSeconds, 17)
        XCTAssertEqual(app.settings.overlapPortion, 0.15)
    }

    func testStrictModeIsIndependentOfProcessingProfile() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingProfileTests")
        let app = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )

        app.updateInferenceMode(.strict)
        app.selectProcessingProfile(.extended)
        XCTAssertEqual(app.inferenceMode, .strict)

        let restored = AppState(
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(prefix: "ProcessingProfileTests")
        )
        XCTAssertEqual(restored.inferenceMode, .strict)
        XCTAssertEqual(restored.processingProfile, .extended)
    }
}
