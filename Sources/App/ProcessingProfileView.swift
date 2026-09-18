// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct ProcessingProfileView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var menuPresentation: MenuWindowPresentationController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringResource.profileSectionTitle)
                .sectionLabelStyle()
            ProcessingProfileSegmentedControl(selection: Binding(
                get: { app.processingProfile },
                set: { app.selectProcessingProfile($0) }
            ), isEnabled: app.canChangeSettings)
            .frame(maxWidth: .infinity)

            Text(app.processingProfile.detail)
                .font(.caption)
                .foregroundStyle(.secondary)

            if app.processingProfile == .custom {
                VStack(alignment: .leading, spacing: 12) {
                    settingSlider(
                        title: LocalizedStringResource.profileCustomChunkSize,
                        valueLabel: .profileCustomChunkSeconds(
                            Int(app.settings.chunkSeconds.rounded())
                        ),
                        value: Binding(
                            get: { app.settings.chunkSeconds },
                            set: { app.updateChunkSeconds($0) }
                        ),
                        range: 1...60,
                        step: 1
                    )
                    settingSlider(
                        title: LocalizedStringResource.profileCustomOverlap,
                        valueLabel: .profileCustomOverlapPercent(
                            Int((app.settings.overlapPortion * 100).rounded())
                        ),
                        value: Binding(
                            get: { app.settings.overlapPortion },
                            set: { app.updateOverlapPortion($0) }
                        ),
                        range: 0...0.5,
                        step: 0.05
                    )
                }
                .padding(12)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(Color.primary.opacity(0.06))
                )
            }

            VStack(alignment: .leading, spacing: 0) {
                DisclosureHeader(
                    title: LocalizedStringResource.profileAdvancedTitle,
                    isExpanded: menuPresentation.isAdvancedExpanded,
                    trailingSummary: strictModeEnabled && !menuPresentation.isAdvancedExpanded
                        ? LocalizedStringResource.profileStrictModeSummary
                        : nil
                ) {
                    menuPresentation.toggleAdvancedDisclosure()
                }

                if menuPresentation.isAdvancedExpanded {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle(
                            LocalizedStringResource.profileStrictModeCheckboxTitle,
                            isOn: Binding(
                                get: { strictModeEnabled },
                                set: { app.updateInferenceMode($0 ? .strict : .standard) }
                            )
                        )
                        .font(.caption)
                        .toggleStyle(.checkbox)
                        .disabled(!app.canChangeSettings)

                        Text(LocalizedStringResource.profileStrictModeHelp)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.top, 8)
                    .padding(.leading, 16)
                }
            }
        }
    }

    private var strictModeEnabled: Bool {
        app.inferenceMode == .strict
    }

    private func settingSlider(
        title: LocalizedStringResource,
        valueLabel: LocalizedStringResource,
        value: Binding<Double>,
        range: ClosedRange<Double>,
        step: Double
    ) -> some View {
        VStack(spacing: 5) {
            HStack { Text(title); Spacer(); Text(valueLabel).foregroundStyle(.secondary) }
                .font(.caption)
            Slider(value: value, in: range, step: step).disabled(!app.canChangeSettings)
        }
    }
}
