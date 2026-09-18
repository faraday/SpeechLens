// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import App

final class AppOnboardingPreferenceTests: XCTestCase {
    func testMissingAcceptedVersionRequiresOnboarding() {
        let defaults = makeDefaults()

        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
    }

    func testVersionOneAcceptanceRequiresFreshSentryDisclosure() {
        let defaults = makeDefaults()
        defaults.set(1, forKey: AppOnboardingPreference.acceptedVersionKey)

        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
    }

    func testVersionTwoAcceptanceRequiresPerformanceDisclosure() {
        let defaults = makeDefaults()
        defaults.set(2, forKey: AppOnboardingPreference.acceptedVersionKey)

        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
    }

    func testCurrentAcceptedVersionSkipsOnboarding() {
        let defaults = makeDefaults()
        defaults.set(
            AppOnboardingPreference.requiredVersion,
            forKey: AppOnboardingPreference.acceptedVersionKey
        )

        XCTAssertFalse(AppOnboardingPreference.isRequired(in: defaults))
    }

    func testObsoletePresentationAndOnboardingKeysDoNotSuppressOnboarding() {
        let defaults = makeDefaults()
        defaults.set(true, forKey: "hasCompletedOnboarding")
        defaults.set(
            true,
            forKey: "SpeechLens.hasShownPrivacyCopyPresentation.v1"
        )

        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
    }

    func testChoicesRemainUnchangedUntilAcceptance() {
        let defaults = makeDefaults()
        AppPrivacyPreference.migrateIfNeeded(in: defaults)

        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
    }

    func testAcceptancePersistsThreeCanonicalPermissionsAndVersion() {
        let defaults = makeDefaults()
        var downloadCount = 0

        AppOnboardingPreference.accept(
            reliabilityReporting: false,
            enhancementPerformance: true,
            modelIsReady: true,
            in: defaults
        ) {
            downloadCount += 1
        }

        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertFalse(defaults.bool(forKey: AppPrivacyPreference.basicDiagnosticsKey))
        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.enhancementPerformanceKey))
        XCTAssertEqual(
            defaults.integer(forKey: AppOnboardingPreference.acceptedVersionKey),
            AppOnboardingPreference.requiredVersion
        )
        XCTAssertFalse(AppOnboardingPreference.isRequired(in: defaults))
        XCTAssertEqual(downloadCount, 0)
    }

    func testAcceptanceStartsOneDownloadWhenModelIsMissing() {
        let defaults = makeDefaults()
        var downloadCount = 0

        AppOnboardingPreference.accept(
            reliabilityReporting: true,
            enhancementPerformance: false,
            modelIsReady: false,
            in: defaults
        ) {
            downloadCount += 1
        }

        XCTAssertEqual(downloadCount, 1)
        XCTAssertFalse(AppOnboardingPreference.isRequired(in: defaults))
    }

    private func makeDefaults() -> UserDefaults {
        let suiteName = "AppOnboardingPreferenceTests.\(UUID().uuidString)"
        let defaults = try! XCTUnwrap(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }
}
