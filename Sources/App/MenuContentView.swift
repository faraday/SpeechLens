// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var modelStore: ModelStore
    @EnvironmentObject private var menuPresentation: MenuWindowPresentationController
    @AppStorage(AppOnboardingPreference.acceptedVersionKey)
    private var acceptedOnboardingVersion = 0
    @AppStorage(AppPrivacyPreference.crashReportingKey)
    private var crashReportingEnabled = AppPrivacyPreference.crashReportingDefault
    @AppStorage(AppPrivacyPreference.basicDiagnosticsKey)
    private var basicDiagnosticsEnabled = AppPrivacyPreference.basicDiagnosticsDefault
    @AppStorage(AppPrivacyPreference.enhancementPerformanceKey)
    private var enhancementPerformanceEnabled = AppPrivacyPreference.enhancementPerformanceDefault

    var body: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    Group {
                        if onboardingIsRequired {
                            onboardingContent
                        } else {
                            content
                        }
                    }
                    .background(
                        GeometryReader { proxy in
                            Color.clear.preference(
                                key: MenuContentHeightPreferenceKey.self,
                                value: proxy.size.height
                            )
                        }
                    )
                }
                .scrollIndicators(.visible)
                .onChange(of: app.workflow) { _, workflow in
                    guard case .completed = workflow else { return }
                    withAnimation { proxy.scrollTo(MenuScrollTarget.preview, anchor: .top) }
                }
                .onChange(of: menuPresentation.isPrivacyExpanded) { _, isExpanded in
                    guard isExpanded else { return }
                    withAnimation { proxy.scrollTo(MenuScrollTarget.privacy, anchor: .top) }
                }
                .onChange(of: menuPresentation.isAdvancedExpanded) { _, isExpanded in
                    guard isExpanded else { return }
                    withAnimation { proxy.scrollTo(MenuScrollTarget.advanced, anchor: .bottom) }
                }
                .onChange(of: menuPresentation.isAboutExpanded) { _, isExpanded in
                    guard isExpanded else { return }
                    withAnimation { proxy.scrollTo(MenuScrollTarget.about, anchor: .bottom) }
                }
            }
            Divider()
            MenuFooterView()
                .padding(.horizontal, 16)
                .frame(height: MenuWindowLayout.footerHeight)
        }
        .frame(width: MenuWindowLayout.width, height: menuPresentation.height)
        .background(Color(nsColor: .windowBackgroundColor))
        .onPreferenceChange(MenuContentHeightPreferenceKey.self) { height in
            menuPresentation.requestContentHeight(height + MenuWindowLayout.footerHeight)
        }
    }

    private var onboardingIsRequired: Bool {
        acceptedOnboardingVersion < AppOnboardingPreference.requiredVersion
    }

    private var onboardingContent: some View {
        OnboardingWelcomeView(
            modelIsReady: modelStore.state.isReady,
            modelLicenseURL: modelStore.descriptor.licenseURL,
            expectedModelSizeBytes: modelStore.descriptor.expectedSizeBytes,
            initialReliabilityReporting: crashReportingEnabled && basicDiagnosticsEnabled,
            initialEnhancementPerformance: enhancementPerformanceEnabled
        ) { reliabilityReporting, enhancementPerformance in
            AppOnboardingPreference.accept(
                reliabilityReporting: reliabilityReporting,
                enhancementPerformance: enhancementPerformance,
                modelIsReady: modelStore.state.isReady,
                in: .standard
            ) {
                app.downloadModel()
            }
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 16) {
            MenuHeaderView()
            if !modelStore.state.isReady || modelStore.state.isDownloading {
                ModelSetupSectionView()
            }
            if modelStore.state.isReady {
                WorkflowSectionView()
                ProcessingProfileView()
                    .id(MenuScrollTarget.advanced)
            }
            if let selectedInputURL = app.workflow.selectedInputURL {
                SelectedFileSectionView(url: selectedInputURL)
            }
            if case .selectingAudioTrack = app.workflow {
                AudioTrackSelectionSectionView()
            }
            ProcessingSectionView()
            if case .completed = app.workflow {
                CompletionSectionView()
                    .id(MenuScrollTarget.preview)
            }
            PrivacySectionView()
                .id(MenuScrollTarget.privacy)
            AboutSectionView()
                .id(MenuScrollTarget.about)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private enum MenuScrollTarget: Hashable {
    case preview
    case advanced
    case privacy
    case about
}

private struct MenuContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = MenuWindowLayout.minimumHeight

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
