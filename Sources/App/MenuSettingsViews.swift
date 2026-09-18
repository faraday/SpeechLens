// SPDX-License-Identifier: Apache-2.0

import AppKit
import Diagnostics
import MediaIO
import SwiftUI

enum AppPrivacyPreference {
    static let crashReportingKey = "telemetry.crashReportingEnabled"
    static let basicDiagnosticsKey = "telemetry.basicDiagnosticsEnabled"
    static let enhancementPerformanceKey = "telemetry.enhancementPerformanceEnabled"

    static let crashReportingDefault = true
    static let basicDiagnosticsDefault = true
    static let enhancementPerformanceDefault = true

    private static let legacyCrashReportingKey = "enableCrashReporting"
    private static let legacyResearchBenchmarksKey = "enableResearchBenchmarks"
    private static let migrationKey = "telemetry.preferencesMigration.v1"

    static func migrateIfNeeded(in defaults: UserDefaults) {
        guard !defaults.bool(forKey: migrationKey) else { return }

        let legacyCrashReporting = defaults.object(
            forKey: legacyCrashReportingKey
        ) as? Bool
        seedIfMissing(
            crashReportingKey,
            value: legacyCrashReporting ?? crashReportingDefault,
            in: defaults
        )
        seedIfMissing(
            basicDiagnosticsKey,
            value: legacyCrashReporting ?? basicDiagnosticsDefault,
            in: defaults
        )

        let legacyResearchBenchmarks = defaults.object(
            forKey: legacyResearchBenchmarksKey
        ) as? Bool
        seedIfMissing(
            enhancementPerformanceKey,
            value: legacyResearchBenchmarks ?? enhancementPerformanceDefault,
            in: defaults
        )

        defaults.set(true, forKey: migrationKey)
    }

    static func reliabilityReportingBinding(
        crashReporting: Binding<Bool>,
        basicDiagnostics: Binding<Bool>
    ) -> Binding<Bool> {
        Binding(
            get: { crashReporting.wrappedValue && basicDiagnostics.wrappedValue },
            set: { isEnabled in
                crashReporting.wrappedValue = isEnabled
                basicDiagnostics.wrappedValue = isEnabled
            }
        )
    }

    private static func seedIfMissing(
        _ key: String,
        value: Bool,
        in defaults: UserDefaults
    ) {
        guard defaults.object(forKey: key) == nil else { return }
        defaults.set(value, forKey: key)
    }
}

struct PrivacySectionView: View {
    @EnvironmentObject private var presentation: MenuWindowPresentationController
    @AppStorage(AppPrivacyPreference.crashReportingKey)
    private var crashReportingEnabled = AppPrivacyPreference.crashReportingDefault
    @AppStorage(AppPrivacyPreference.basicDiagnosticsKey)
    private var basicDiagnosticsEnabled = AppPrivacyPreference.basicDiagnosticsDefault
    @AppStorage(AppPrivacyPreference.enhancementPerformanceKey)
    private var enhancementPerformanceEnabled = AppPrivacyPreference.enhancementPerformanceDefault

    private var privacyPolicyURL: URL {
        URL(string: "https://github.com/faraday/SpeechLens/blob/main/PRIVACY_POLICY.md") ?? URL(fileURLWithPath: "/")
    }

    private var reliabilityReporting: Binding<Bool> {
        AppPrivacyPreference.reliabilityReportingBinding(
            crashReporting: $crashReportingEnabled,
            basicDiagnostics: $basicDiagnosticsEnabled
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureHeader(
                title: LocalizedStringResource.settingsPrivacyTitle,
                isExpanded: presentation.isPrivacyExpanded
            ) {
                presentation.togglePrivacyDisclosure()
            }
            if presentation.isPrivacyExpanded {
                privacyContent
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var privacyContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource.settingsPrivacyLocalDiagnostics)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Toggle(
                LocalizedStringResource.settingsPrivacyCrashReports,
                isOn: reliabilityReporting
            )
                .font(.caption)
                .toggleStyle(.checkbox)

            Toggle(
                LocalizedStringResource.settingsPrivacyEnhancementPerformance,
                isOn: $enhancementPerformanceEnabled
            )
                .font(.caption)
                .toggleStyle(.checkbox)

            Divider()

            HStack {
                Link(
                    LocalizedStringResource.settingsPrivacyPolicyLink,
                    destination: privacyPolicyURL
                )
                    .font(.caption)
                    .foregroundStyle(Color.blue)

                Spacer()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AboutSectionView: View {
    @EnvironmentObject private var modelStore: ModelStore
    @EnvironmentObject private var presentation: MenuWindowPresentationController

    private var authorURL: URL {
        URL(string: "https://cagataycalli.com") ?? URL(fileURLWithPath: "/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            DisclosureHeader(
                title: LocalizedStringResource.settingsAboutTitle,
                isExpanded: presentation.isAboutExpanded
            ) {
                presentation.toggleAboutDisclosure()
            }
            if presentation.isAboutExpanded {
                aboutContent
                    .font(.caption)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
                    .background(
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.06))
                    )
                    .padding(.top, 8)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var aboutContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            linkRow(
                LocalizedStringResource.settingsAboutSourceModel,
                "nvidia/RE-USE",
                modelStore.descriptor.sourceModelURL
            )
            linkRow(
                LocalizedStringResource.settingsAboutConvertedWeights,
                "faraday/re-use-mlx",
                modelStore.descriptor.convertedWeightsURL
            )
            linkRow(
                LocalizedStringResource.settingsAboutModelLicense,
                "NVIDIA One-Way Noncommercial",
                modelStore.descriptor.licenseURL
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(LocalizedStringResource.settingsAboutLicenseNotice)
                Text(LocalizedStringResource.settingsAboutLocalProcessing)
            }
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.top, 4)

            Divider().padding(.vertical, 2)

            HStack {
                Text(LocalizedStringResource.settingsAboutAuthorLabel)
                    .foregroundStyle(.secondary)
                Spacer()
                Link(
                    LocalizedStringResource.settingsAboutAuthorLink,
                    destination: authorURL
                )
                    .foregroundStyle(Color.blue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func linkRow(
        _ label: LocalizedStringResource,
        _ title: String,
        _ destination: URL
    ) -> some View {
        HStack {
            Text(label)
            Spacer()
            Link(destination: destination) { Text(verbatim: title) }
                .foregroundStyle(Color.blue)
        }
    }
}

struct MenuFooterView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(
                LocalizedStringResource.settingsFooterAppVersion(
                    DiagnosticEnvironment.current().appVersion
                )
            )
            .font(.caption)
            .foregroundStyle(.secondary)
            .textSelection(.enabled)

            Spacer()

            Button(LocalizedStringResource.appActionQuit) {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
            .controlSize(.small)
            .disabled(app.workflow.isBusy)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }
}
