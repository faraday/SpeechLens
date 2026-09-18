// SPDX-License-Identifier: Apache-2.0

import Foundation
import SwiftUI

enum AppOnboardingPreference {
    // Version 4 adds pseudonymous daily activity and session reporting.
    // Earlier acceptance cannot authorize the expanded data contract.
    static let requiredVersion = 4
    static let acceptedVersionKey = "SpeechLens.acceptedOnboardingVersion"

    static func isRequired(in defaults: UserDefaults) -> Bool {
        defaults.integer(forKey: acceptedVersionKey) < requiredVersion
    }

    static func accept(
        reliabilityReporting: Bool,
        enhancementPerformance: Bool,
        modelIsReady: Bool,
        in defaults: UserDefaults,
        startModelDownload: () -> Void
    ) {
        defaults.set(
            reliabilityReporting,
            forKey: AppPrivacyPreference.crashReportingKey
        )
        defaults.set(
            reliabilityReporting,
            forKey: AppPrivacyPreference.basicDiagnosticsKey
        )
        defaults.set(
            enhancementPerformance,
            forKey: AppPrivacyPreference.enhancementPerformanceKey
        )

        // Commit acceptance last so an interrupted write cannot skip onboarding.
        defaults.set(requiredVersion, forKey: acceptedVersionKey)

        if !modelIsReady {
            startModelDownload()
        }
    }
}

struct OnboardingWelcomeView: View {
    let modelIsReady: Bool
    let modelLicenseURL: URL
    let expectedModelSizeBytes: Int64
    let initialReliabilityReporting: Bool
    let initialEnhancementPerformance: Bool
    let onAccept: (_ reliabilityReporting: Bool, _ enhancementPerformance: Bool) -> Void

    @State private var reliabilityReporting: Bool
    @State private var enhancementPerformance: Bool

    init(
        modelIsReady: Bool,
        modelLicenseURL: URL,
        expectedModelSizeBytes: Int64,
        initialReliabilityReporting: Bool,
        initialEnhancementPerformance: Bool,
        onAccept: @escaping (_ reliabilityReporting: Bool, _ enhancementPerformance: Bool) -> Void
    ) {
        self.modelIsReady = modelIsReady
        self.modelLicenseURL = modelLicenseURL
        self.expectedModelSizeBytes = expectedModelSizeBytes
        self.initialReliabilityReporting = initialReliabilityReporting
        self.initialEnhancementPerformance = initialEnhancementPerformance
        self.onAccept = onAccept
        _reliabilityReporting = State(initialValue: initialReliabilityReporting)
        _enhancementPerformance = State(initialValue: initialEnhancementPerformance)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "waveform.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource.onboardingWelcomeTitle)
                        .font(.headline)
                    Text(LocalizedStringResource.onboardingWelcomeSubtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 7) {
                Label(
                    LocalizedStringResource.onboardingModelTitle,
                    systemImage: "doc.text.fill"
                )
                    .font(.caption)
                    .fontWeight(.semibold)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource.onboardingModelIdentity)
                    Text(LocalizedStringResource.onboardingModelRestriction)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                if let downloadRequirement = OnboardingModelPresentation.downloadRequirement(
                    modelIsReady: modelIsReady,
                    expectedSizeBytes: expectedModelSizeBytes
                ) {
                    Text(downloadRequirement)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Link(
                    LocalizedStringResource.onboardingModelLicenseLink,
                    destination: modelLicenseURL
                )
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )

            VStack(alignment: .leading, spacing: 10) {
                Label(
                    LocalizedStringResource.onboardingDiagnosticsTitle,
                    systemImage: "shield.checkerboard"
                )
                    .font(.caption)
                    .fontWeight(.semibold)

                Toggle(
                    LocalizedStringResource.settingsPrivacyCrashReports,
                    isOn: $reliabilityReporting
                )
                    .font(.caption)
                    .toggleStyle(.checkbox)

                Toggle(
                    LocalizedStringResource.settingsPrivacyEnhancementPerformance,
                    isOn: $enhancementPerformance
                )
                    .font(.caption)
                    .toggleStyle(.checkbox)

                VStack(alignment: .leading, spacing: 2) {
                    Text(LocalizedStringResource.onboardingDiagnosticsLocalProcessing)
                    Text(LocalizedStringResource.onboardingDiagnosticsDataExclusions)
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

                Link(
                    LocalizedStringResource.settingsPrivacyPolicyLink,
                    destination: privacyPolicyURL
                )
                    .font(.caption)
                    .foregroundStyle(Color.blue)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.primary.opacity(0.06))
            )

            VStack(alignment: .leading, spacing: 8) {
                Text(LocalizedStringResource.onboardingModelAgreement)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack {
                    Spacer()

                    Button {
                        onAccept(reliabilityReporting, enhancementPerformance)
                    } label: {
                        Text(primaryActionTitle)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear {
            reliabilityReporting = initialReliabilityReporting
            enhancementPerformance = initialEnhancementPerformance
        }
    }

    private var primaryActionTitle: LocalizedStringResource {
        modelIsReady
            ? .onboardingActionAgreeContinue
            : .onboardingActionAgreeDownload
    }

    private var privacyPolicyURL: URL {
        URL(
            string: "https://github.com/faraday/SpeechLens/blob/main/PRIVACY_POLICY.md"
        ) ?? URL(fileURLWithPath: "/")
    }
}

enum OnboardingModelPresentation {
    static func downloadRequirement(
        modelIsReady: Bool,
        expectedSizeBytes: Int64,
        locale: Locale = .current
    ) -> LocalizedStringResource? {
        guard !modelIsReady else { return nil }
        let style = ByteCountFormatStyle(style: .file).locale(locale)
        return .onboardingModelDownloadRequirement(
            expectedSizeBytes.formatted(style)
        )
    }
}
