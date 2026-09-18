// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import XCTest
@testable import App

@MainActor
final class ProcessingSettingsStoreTests: XCTestCase {
    func testFirstRunAndInvalidProfileRestoreFastDefaults() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingSettingsStoreTests")
        let store = ProcessingSettingsStore(defaults: defaults)
        XCTAssertEqual(store.loadProfile(), .fast)
        XCTAssertNil(store.loadCustomSettings())

        defaults.set("not-a-profile", forKey: "processingProfile")
        XCTAssertEqual(store.loadProfile(), .fast)
    }

    func testNamedProfileAndCustomSettingsPersistAcrossStoreInstances() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingSettingsStoreTests")
        let settings = try InferenceSettings(chunkSeconds: 17, overlapPortion: 0.15)
        let store = ProcessingSettingsStore(defaults: defaults)
        store.saveProfile(.custom)
        store.saveCustomSettings(settings)

        let restored = ProcessingSettingsStore(defaults: defaults)
        XCTAssertEqual(restored.loadProfile(), .custom)
        XCTAssertEqual(restored.loadCustomSettings(), settings)

        restored.saveProfile(.extended)
        XCTAssertEqual(ProcessingSettingsStore(defaults: defaults).loadProfile(), .extended)
        XCTAssertEqual(
            ProcessingSettingsStore(defaults: defaults).loadCustomSettings(),
            settings
        )
    }

    func testInvalidCustomPayloadFallsBackWithoutThrowing() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingSettingsStoreTests")
        defaults.set(Data("invalid-json".utf8), forKey: "customProcessingSettings")

        XCTAssertNil(ProcessingSettingsStore(defaults: defaults).loadCustomSettings())
    }

    func testInferenceModeDefaultsToStandardAndPersistsStrict() throws {
        let defaults = try makeIsolatedDefaults(prefix: "ProcessingSettingsStoreTests")
        let store = ProcessingSettingsStore(defaults: defaults)
        XCTAssertEqual(store.loadInferenceMode(), .standard)

        store.saveInferenceMode(.strict)
        XCTAssertEqual(
            ProcessingSettingsStore(defaults: defaults).loadInferenceMode(),
            .strict
        )
    }
}
