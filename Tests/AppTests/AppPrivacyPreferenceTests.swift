// SPDX-License-Identifier: Apache-2.0

import SwiftUI
import XCTest
@testable import App

final class AppPrivacyPreferenceTests: XCTestCase {
    func testMissingPreferencesReceiveFinalDefaults() {
        let defaults = makeDefaults()
        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        let crashReporting = AppStorage(
            wrappedValue: AppPrivacyPreference.crashReportingDefault,
            AppPrivacyPreference.crashReportingKey,
            store: defaults
        )
        let basicDiagnostics = AppStorage(
            wrappedValue: AppPrivacyPreference.basicDiagnosticsDefault,
            AppPrivacyPreference.basicDiagnosticsKey,
            store: defaults
        )
        let enhancementPerformance = AppStorage(
            wrappedValue: AppPrivacyPreference.enhancementPerformanceDefault,
            AppPrivacyPreference.enhancementPerformanceKey,
            store: defaults
        )

        XCTAssertTrue(crashReporting.wrappedValue)
        XCTAssertTrue(basicDiagnostics.wrappedValue)
        XCTAssertTrue(enhancementPerformance.wrappedValue)
    }

    func testLegacyTrueChoicesSeedCanonicalPreferences() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "enableCrashReporting")
        defaults.set(true, forKey: "enableResearchBenchmarks")

        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
    }

    func testLegacyFalseChoicesSeedCanonicalPreferences() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "enableCrashReporting")
        defaults.set(false, forKey: "enableResearchBenchmarks")

        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
    }

    func testMigrationPreservesExistingCanonicalChoices() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(true, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        defaults.set(true, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        defaults.set(true, forKey: "enableCrashReporting")
        defaults.set(false, forKey: "enableResearchBenchmarks")

        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
    }

    func testMigrationRunsOnlyOnce() {
        let defaults = makeDefaults()
        defaults.set(false, forKey: "enableCrashReporting")
        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        defaults.set(true, forKey: "enableCrashReporting")
        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
    }

    func testReliabilityBindingReadsBothAndWritesBoth() {
        var crashReporting = true
        var basicDiagnostics = false
        let binding = AppPrivacyPreference.reliabilityReportingBinding(
            crashReporting: Binding(
                get: { crashReporting },
                set: { crashReporting = $0 }
            ),
            basicDiagnostics: Binding(
                get: { basicDiagnostics },
                set: { basicDiagnostics = $0 }
            )
        )

        XCTAssertFalse(binding.wrappedValue)

        binding.wrappedValue = true
        XCTAssertTrue(crashReporting)
        XCTAssertTrue(basicDiagnostics)

        binding.wrappedValue = false
        XCTAssertFalse(crashReporting)
        XCTAssertFalse(basicDiagnostics)
    }

    func testPerformancePreferenceRemainsIndependent() {
        let defaults = makeDefaults()
        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)

        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
        defaults.set(false, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
        defaults.set(true, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppPrivacyPreferenceTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
