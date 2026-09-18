// SPDX-License-Identifier: Apache-2.0

import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let menuPresentation = MenuWindowPresentationController()
    private let telemetry: AppTelemetryCoordinator
    private lazy var menuBar = MenuBarPopoverCoordinator(
        appState: appState,
        presentation: menuPresentation,
        recordActivity: { [weak self] in
            self?.telemetry.recordDailyActivityIfNeeded()
        }
    )

    override init() {
        let telemetry = AppTelemetryCoordinator(
            reporter: SentryCrashReporter()
        )
        self.telemetry = telemetry
        appState = AppState(performanceReporter: telemetry)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        let defaults = UserDefaults.standard
        AppPrivacyPreference.migrateIfNeeded(in: defaults)
        telemetry.start(initialReport: appState.latestDiagnosticReport())
        appState.observeDiagnosticReports { [weak self] report in
            self?.telemetry.update(report: report)
        }
        menuBar.install()

        let initialPresentation = LaunchMenuPresentation(
            onboardingIsRequired: AppOnboardingPreference.isRequired(
                in: defaults
            ),
            modelIsReady: appState.modelStore.state.isReady
        )
        if initialPresentation.shouldShow {
            Task { @MainActor [weak self] in
                await Task.yield()
                self?.menuBar.show()
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        appState.prepareForApplicationTermination()
    }
}

@main
struct SpeechLensApp {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.run()
    }
}
