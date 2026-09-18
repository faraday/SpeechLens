// SPDX-License-Identifier: Apache-2.0

import Foundation
import Diagnostics
import MediaIO
import SwiftUI
import XCTest
@testable import App

final class AppLocalizationTests: XCTestCase {
    func testEnglishCatalogResolvesSemanticKey() {
        let resource = LocalizedStringResource.appName

        XCTAssertEqual(
            englishText(resource),
            "SpeechLens"
        )
    }

    func testSettingsCopyResolvesFromCatalog() throws {
        let expected: [(String, LocalizedStringResource, String)] = [
            (
                "profile.advanced.title",
                .profileAdvancedTitle,
                "Advanced processing"
            ),
            (
                "profile.strict_mode.checkbox_title",
                .profileStrictModeCheckboxTitle,
                "Strict numerical mode"
            ),
            (
                "profile.strict_mode.help",
                .profileStrictModeHelp,
                "Uses stricter calculations for closer agreement with the reference model."
            ),
            (
                "profile.strict_mode.summary",
                .profileStrictModeSummary,
                "Strict on"
            ),
            (
                "settings.disclosure.collapsed",
                .settingsDisclosureCollapsed,
                "Collapsed"
            ),
            (
                "settings.disclosure.expanded",
                .settingsDisclosureExpanded,
                "Expanded"
            ),
            (
                "settings.privacy.title",
                .settingsPrivacyTitle,
                "Privacy & Diagnostics"
            ),
            (
                "settings.privacy.local_diagnostics",
                .settingsPrivacyLocalDiagnostics,
                "Your audio stays on your Mac.\nDiagnostics go to Sentry in the EU.\nAudio, filenames, paths, and transcripts are never included."
            ),
            (
                "settings.privacy.crash_reports",
                .settingsPrivacyCrashReports,
                "Send crash reports and basic diagnostics"
            ),
            (
                "settings.privacy.enhancement_performance",
                .settingsPrivacyEnhancementPerformance,
                "Help improve enhancement performance"
            ),
            (
                "settings.privacy.policy_link",
                .settingsPrivacyPolicyLink,
                "Privacy details…"
            ),
            (
                "onboarding.welcome.title",
                .onboardingWelcomeTitle,
                "Welcome to SpeechLens"
            ),
            (
                "onboarding.welcome.subtitle",
                .onboardingWelcomeSubtitle,
                "On-device speech enhancement."
            ),
            (
                "onboarding.model.title",
                .onboardingModelTitle,
                "Model use"
            ),
            (
                "onboarding.model.identity",
                .onboardingModelIdentity,
                "SpeechLens uses NVIDIA’s RE-USE model."
            ),
            (
                "onboarding.model.restriction",
                .onboardingModelRestriction,
                "It is licensed for non-commercial research and educational use only."
            ),
            (
                "onboarding.model.license_link",
                .onboardingModelLicenseLink,
                "View NVIDIA One-Way Noncommercial License (NSCLv1)…"
            ),
            (
                "onboarding.model.agreement",
                .onboardingModelAgreement,
                "By continuing, you agree to use the model only as permitted by its license."
            ),
            (
                "onboarding.diagnostics.title",
                .onboardingDiagnosticsTitle,
                "Diagnostics"
            ),
            (
                "onboarding.diagnostics.local_processing",
                .onboardingDiagnosticsLocalProcessing,
                "Your audio stays on your Mac."
            ),
            (
                "onboarding.diagnostics.data_exclusions",
                .onboardingDiagnosticsDataExclusions,
                "Diagnostics go to Sentry in the EU.\nAudio, filenames, paths, and transcripts are never included."
            ),
            (
                "onboarding.action.agree_download",
                .onboardingActionAgreeDownload,
                "Agree & Download Model"
            ),
            (
                "onboarding.action.agree_continue",
                .onboardingActionAgreeContinue,
                "Agree & Continue"
            ),
            (
                "settings.about.author_label",
                .settingsAboutAuthorLabel,
                "Built by"
            ),
            (
                "settings.about.author_link",
                .settingsAboutAuthorLink,
                "Çağatay Çallı"
            ),
        ]

        let english = try englishCatalogValues()
        for (key, resource, expectedValue) in expected {
            XCTAssertEqual(english[key], expectedValue, key)
            XCTAssertEqual(englishText(resource), expectedValue, key)
        }

        XCTAssertEqual(english["settings.footer.app_version"], "Version %@")
        XCTAssertEqual(
            englishText(.settingsFooterAppVersion("1.2.3")),
            "Version 1.2.3"
        )
    }

    func testCatalogHasEnglishCopyCommentsAndNoCheckedInDerivedStrings() throws {
        let catalogURL = projectRoot.appendingPathComponent(
            "Sources/App/Localization/Localizable.xcstrings"
        )
        let catalogData = try Data(contentsOf: catalogURL)
        let catalogObject = try XCTUnwrap(
            JSONSerialization.jsonObject(with: catalogData) as? [String: Any]
        )
        let strings = try XCTUnwrap(
            catalogObject["strings"] as? [String: Any]
        )
        let catalogKeys = Set(strings.keys)
        XCTAssertEqual(
            Set(catalogKeys.filter { $0.hasPrefix("failure.") }),
            Set(DiagnosticFailureCode.allCases.map {
                "failure.\($0.rawValue)"
            })
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: projectRoot.appendingPathComponent(
                    "Sources/App/Localization/en.lproj/Localizable.strings"
                ).path
            )
        )
        for (key, value) in strings {
            let entry = try XCTUnwrap(value as? [String: Any], key)
            XCTAssertFalse((entry["comment"] as? String ?? "").isEmpty, key)
            let localizations = try XCTUnwrap(
                entry["localizations"] as? [String: Any],
                key
            )
            let english = try XCTUnwrap(
                localizations["en"] as? [String: Any],
                key
            )
            let unit = try XCTUnwrap(
                english["stringUnit"] as? [String: Any],
                key
            )
            XCTAssertFalse((unit["value"] as? String ?? "").isEmpty, key)
        }

        let rawCatalog = try String(contentsOf: catalogURL, encoding: .utf8)
        let keyPattern = try NSRegularExpression(
            pattern: #""([a-z][a-z0-9_]*(?:\.[a-z0-9_]+)+)"\s*:\s*\{"#
        )
        let matches = keyPattern.matches(
            in: rawCatalog,
            range: NSRange(rawCatalog.startIndex..., in: rawCatalog)
        )
        let declaredKeys = try matches.map { match in
            let range = try XCTUnwrap(Range(match.range(at: 1), in: rawCatalog))
            return String(rawCatalog[range])
        }
        XCTAssertEqual(declaredKeys.count, Set(declaredKeys).count)

    }

    func testEveryFailureCodeHasUniqueControlledCopyAndRejectsTechnicalDetail()
        throws
    {
        let hostile = "\(AppPrivacyTestFixture.inputURL.path) "
            + "https://\(AppPrivacyTestFixture.sensitiveHost) raw ffmpeg tail"
        let english = try englishCatalogValues()
        let failureKeys = Set(DiagnosticFailureCode.allCases.map {
            AppFailurePresentation.localizationKey(for: $0)
        })
        XCTAssertEqual(
            Set(english.keys.filter { $0.hasPrefix("failure.") }),
            failureKeys
        )
        XCTAssertEqual(
            Set(try failureKeys.map { try XCTUnwrap(english[$0]) }).count,
            DiagnosticFailureCode.allCases.count
        )

        for code in DiagnosticFailureCode.allCases {
            let key = AppFailurePresentation.localizationKey(for: code)
            let expected = try XCTUnwrap(english[key])
            let directMessage = englishText(
                AppFailurePresentation.message(for: code)
            )
            XCTAssertEqual(directMessage, expected, code.rawValue)
            XCTAssertFalse(directMessage.isEmpty, code.rawValue)

            let failure = AppWorkflowFailure(
                category: .processing,
                code: code,
                technicalDetail: hostile,
                job: nil,
                info: nil
            )
            let message = englishText(
                AppFailurePresentation.message(for: failure)
            )
            XCTAssertEqual(message, expected, code.rawValue)
            XCTAssertFalse(message.contains(hostile), code.rawValue)
            XCTAssertFalse(
                message.contains(AppPrivacyTestFixture.privatePathPrefix),
                code.rawValue
            )
            XCTAssertFalse(message.contains("ffmpeg tail"), code.rawValue)
        }

        for code in DiagnosticFailureCode.allCases where
            code.rawValue.hasPrefix("model.")
        {
            let key = AppFailurePresentation.localizationKey(for: code)
            XCTAssertEqual(
                englishText(ModelSetupPresentation.detail(for: .failed(
                    ModelSetupFailure(
                        code: code,
                        technicalDetail: hostile
                    )
                ))),
                try XCTUnwrap(english[key]),
                code.rawValue
            )
        }

        XCTAssertEqual(
            englishText(PlaybackIssuePresentation.message(
                for: .previewFileMissing
            )),
            english[AppFailurePresentation.localizationKey(
                for: .playbackPreviewFileMissing
            )]
        )

        XCTAssertEqual(
            englishText(AppFailurePresentation.message(for: .modelDownloadNetwork)),
            "SpeechLens couldn’t reach the model download server. Check your connection and try again."
        )
        XCTAssertEqual(
            englishText(AppFailurePresentation.message(for: .mediaProtectedContent)),
            "Protected media can’t be enhanced."
        )
        XCTAssertEqual(
            englishText(AppFailurePresentation.message(
                for: .processingDestinationUnavailable
            )),
            "SpeechLens couldn’t write the output. Check the destination and try again."
        )
    }

    func testStaticCopyUsesCatalogOnlyAndFormattedDefaultsInterpolate() throws {
        let sourceRoot = projectRoot.appendingPathComponent("Sources/App")
        let sourceURLs = try swiftSourceURLs(in: sourceRoot)

        let directUserFacingLiteralPattern = try NSRegularExpression(
            pattern: #"(?m)^\s*(?:(?:Text|Toggle|Link|Button|DisclosureHeader|LocalizedStringResource)\s*\(\s*\"|accessibilityDescription:\s*\")"#
        )

        for url in sourceURLs {
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertFalse(source.contains("AppLocalization."), url.path)
            XCTAssertTrue(
                directUserFacingLiteralPattern
                    .matches(
                        in: source,
                        range: NSRange(source.startIndex..., in: source)
                    )
                    .isEmpty,
                "Direct UI string literal found in \(url.path)"
            )
            for line in source.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard trimmed.hasPrefix("defaultValue:"),
                      !trimmed.hasPrefix("defaultValue: defaultValue")
                else {
                    continue
                }
                XCTAssertTrue(
                    line.contains(#"\("#),
                    "\(url.lastPathComponent): \(line)"
                )
            }
        }

        let failureSource = try String(
            contentsOf: sourceRoot.appendingPathComponent(
                "AppFailurePresentation.swift"
            ),
            encoding: .utf8
        )
        XCTAssertFalse(failureSource.contains("defaultValue:"))
    }

    func testModelProfilePlaybackAndNoticePresentation() {
        let profileTitles = ["Fast", "Balanced", "Extended", "Custom"]
        XCTAssertEqual(
            ProcessingProfile.allCases.map { englishText($0.title) },
            profileTitles
        )
        XCTAssertEqual(
            ProcessingProfile.allCases.map { englishText($0.detail) },
            [
                "Fast, reliable processing.",
                "More context for most recordings.",
                "More context for long recordings.",
                "Fine-tune chunking and overlap.",
            ]
        )
        XCTAssertEqual(
            PlaybackSelection.allCases.map { englishText($0.title) },
            ["Original", "Enhanced"]
        )
        XCTAssertEqual(
            englishText(AppMediaNoticePresentation.message(
                for: .fallbackContainer(input: .mp4, output: .mov)
            )),
            "The media was written as MOV because the original container could not carry the native-rate output."
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.detail(for: .ready)),
            "Ready for local enhancement."
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.downloadProgress(
                bytes: 1_000_000,
                total: nil,
                fraction: nil,
                locale: Locale(identifier: "en_US")
            )),
            "1 MB downloaded"
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.downloadProgress(
                bytes: 1_000_000,
                total: 2_000_000,
                fraction: 0.5,
                locale: Locale(identifier: "en_US")
            )),
            "1 MB of 2 MB - 50%"
        )
        XCTAssertEqual(
            OnboardingModelPresentation.downloadRequirement(
                modelIsReady: false,
                expectedSizeBytes: 38_583_628,
                locale: Locale(identifier: "en_US")
            ).map {
                englishText($0)
            },
            "Required model download: 38.6 MB"
        )
        XCTAssertNil(
            OnboardingModelPresentation.downloadRequirement(
                modelIsReady: true,
                expectedSizeBytes: 38_583_628,
                locale: Locale(identifier: "en_US")
            )
        )
        XCTAssertEqual(
            OnboardingModelPresentation.downloadRequirement(
                modelIsReady: false,
                expectedSizeBytes: 38_583_628,
                locale: Locale(identifier: "tr_TR")
            ).map {
                englishText($0)
            },
            "Required model download: 38,6 MB"
        )
    }

    @MainActor
    func testOnboardingFitsMenuWindowForMissingAndReadyModel() {
        for modelIsReady in [false, true] {
            let view = OnboardingWelcomeView(
                modelIsReady: modelIsReady,
                modelLicenseURL: URL(string: "https://example.com/license")!,
                expectedModelSizeBytes: 38_583_628,
                initialReliabilityReporting: true,
                initialEnhancementPerformance: false
            ) { _, _ in }
            let hostingView = NSHostingView(rootView: view)
            hostingView.frame.size.width = MenuWindowLayout.width

            XCTAssertLessThanOrEqual(
                hostingView.fittingSize.height + MenuWindowLayout.footerHeight,
                MenuWindowLayout.preferredMaxHeight,
                modelIsReady ? "Installed-model onboarding overflowed" : "Download onboarding overflowed"
            )
        }
    }

    @MainActor
    func testOutputDetailsResolveInterpolatedCatalogValuesInStableOrder() throws {
        let root = try makeTemporaryTestDirectory(
            prefix: "AppLocalizationOutputDetails"
        )
        let fixture = try WorkflowMediaFixture.make(root: root, trackCount: 2)
        let prepared = try XCTUnwrap(fixture.preparedJobs[0])

        let details = OutputDetailsBuilder.build(
            preparedJob: prepared,
            notices: [.auxiliaryStreamsOmitted(streamIndices: [7])]
        )
        XCTAssertEqual(
            details.map { englishText($0.message) },
            [
                "Output format: WAV",
                "Other audio tracks were copied without re-encoding.",
                "Auxiliary timecode, data, attachment, or opaque streams were not carried to the output.",
            ]
        )
        XCTAssertEqual(
            details.map(\.severity),
            [.information, .information, .warning]
        )
    }

    private func swiftSourceURLs(in root: URL) throws -> [URL] {
        let enumerator = try XCTUnwrap(
            FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isRegularFileKey]
            )
        )
        return enumerator.compactMap { element -> URL? in
            guard let url = element as? URL, url.pathExtension == "swift" else {
                return nil
            }
            return url
        }
    }

    private func englishCatalogValues() throws -> [String: String] {
        let catalogURL = projectRoot.appendingPathComponent(
            "Sources/App/Localization/Localizable.xcstrings"
        )
        let data = try Data(contentsOf: catalogURL)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let strings = try XCTUnwrap(object["strings"] as? [String: Any])
        return try strings.reduce(into: [:]) { values, entry in
            let value = try XCTUnwrap(entry.value as? [String: Any])
            let localizations = try XCTUnwrap(
                value["localizations"] as? [String: Any]
            )
            let english = try XCTUnwrap(
                localizations["en"] as? [String: Any]
            )
            let unit = try XCTUnwrap(
                english["stringUnit"] as? [String: Any]
            )
            values[entry.key] = try XCTUnwrap(unit["value"] as? String)
        }
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
