// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation
import XCTest
@testable import App

@MainActor
final class AppCrashReportingTests: XCTestCase {
    func testAllConsentCombinationsSelectExpectedMode() {
        for crashEnabled in [false, true] {
            for basicEnabled in [false, true] {
                for performanceEnabled in [false, true] {
                    let defaults = makeDefaults()
                    defaults.set(
                        AppOnboardingPreference.requiredVersion,
                        forKey: AppOnboardingPreference.acceptedVersionKey
                    )
                    defaults.set(
                        crashEnabled,
                        forKey: AppPrivacyPreference.crashReportingKey
                    )
                    defaults.set(
                        basicEnabled,
                        forKey: AppPrivacyPreference.basicDiagnosticsKey
                    )
                    defaults.set(
                        performanceEnabled,
                        forKey: AppPrivacyPreference.enhancementPerformanceKey
                    )
                    let reporter = RecordingCrashReporter()
                    let coordinator = makeCoordinator(
                        defaults: defaults,
                        reporter: reporter
                    )

                    coordinator.start(initialReport: nil)

                    var expected: TelemetryCapabilities = []
                    if crashEnabled { expected.insert(.crash) }
                    if basicEnabled { expected.insert(.basicDiagnostics) }
                    if performanceEnabled { expected.insert(.performance) }
                    if expected.isEmpty {
                        XCTAssertTrue(reporter.starts.isEmpty)
                    } else {
                        XCTAssertEqual(
                            reporter.starts.last?.capabilities,
                            expected
                        )
                    }
                    coordinator.stop()
                }
            }
        }
    }

    func testOnboardingAcceptanceIsRequiredBeforeDefaultOnConsentStartsReporter() {
        let defaults = makeDefaults()
        AppPrivacyPreference.migrateIfNeeded(in: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)

        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
        XCTAssertTrue(reporter.starts.isEmpty)
        XCTAssertEqual(reporter.stopCount, 1)

        acceptOnboarding(reliability: true, defaults: defaults)
        notify(defaults)

        XCTAssertEqual(reporter.starts.count, 1)
    }

    func testAcceptedCrashConsentIsIndependentFromBasicDiagnostics() {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)

        XCTAssertEqual(reporter.starts.count, 1)
    }

    func testLiveRevocationAndReenableDoNotRestoreTerminalOperationContext() throws {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        let recorder = try makeRecorder()
        recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .default,
            phase: .modelDownloading
        )
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)
        coordinator.start(initialReport: recorder.latestReport())

        XCTAssertNotNil(reporter.starts.last?.operation)
        recorder.cancelCurrentOperation()
        coordinator.update(report: recorder.latestReport())
        XCTAssertNil(reporter.updates.last!)

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)

        XCTAssertEqual(reporter.stopCount, 1)
        XCTAssertEqual(reporter.starts.count, 2)
        XCTAssertNil(reporter.starts.last?.operation)
    }

    func testIdleStartAlwaysCarriesSanitizedEnvironmentContext() {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)

        let environment = reporter.starts.last?.environment.sentryValues
        XCTAssertEqual(environment?["hardware_model"] as? String, "Mac14,5")
        XCTAssertEqual(environment?["macos_version"] as? String, "14.6.1")
        XCTAssertNil(reporter.starts.last?.operation)
    }

    func testConsentEpochUserIDPersistsAcrossModeChangeAndRotatesAfterFullRevocation() {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)
        let firstID = reporter.starts.last?.userID

        defaults.set(true, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        notify(defaults)
        XCTAssertEqual(reporter.starts.last?.userID, firstID)

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        defaults.set(false, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        notify(defaults)
        XCTAssertNil(defaults.string(forKey: "telemetry.consentEpochUserID"))

        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(true, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        notify(defaults)
        XCTAssertNotEqual(reporter.starts.last?.userID, firstID)
    }

    func testDailyActivityEmitsOncePerUTCDay() {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        var now = Date(timeIntervalSince1970: 100)
        let reporter = RecordingCrashReporter()
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: testConfiguration,
            environment: testEnvironment,
            reporter: reporter,
            now: { now }
        )

        coordinator.start(initialReport: nil)
        coordinator.recordDailyActivityIfNeeded()
        XCTAssertEqual(reporter.activities.count, 1)

        now = Date(timeIntervalSince1970: 86_500)
        coordinator.recordDailyActivityIfNeeded()
        XCTAssertEqual(reporter.activities.count, 2)
    }

    func testCrashContextsHaveExactAllowlistedKeysAndDropHostileValues() {
        let hostile: [String: Any] = [
            "event_schema_version": 1,
            "model_artifact_version": "/Users/private/model",
            "operation": "mediaEnhancement",
            "phase": "processingEnhancing",
            "raw_error": "https://private.example/error",
            "filename": "secret.wav",
        ]

        let sanitized = CrashOperationContext.sanitize(hostile)

        XCTAssertEqual(
            Set(sanitized.keys),
            ["event_schema_version", "operation", "phase"]
        )
        XCTAssertTrue(
            Set(sanitized.keys).isSubset(
                of: CrashOperationContext.allowedFieldNames
            )
        )
    }

    func testMalformedOrMissingConfigurationNeverStartsReporter() {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: nil,
            environment: testEnvironment,
            reporter: reporter
        )

        coordinator.start(initialReport: nil)

        XCTAssertTrue(reporter.starts.isEmpty)
        XCTAssertEqual(reporter.stopCount, 1)
    }

    func testDSNValidationAcceptsOnlyFrankfurtIngestProjects() {
        XCTAssertTrue(CrashReportingConfiguration.isAllowedDSN(
            "https://public@o1.ingest.de.sentry.io/123"
        ))
        for rejected in [
            "https://public@o1.ingest.sentry.io/123",
            "https://public@o1.ingest.us.sentry.io/123",
            "https://public@sentry.io/123",
            "http://public@o1.ingest.de.sentry.io/123",
            "https://public@o1.ingest.de.sentry.io/not-a-project",
            "https://public@o1.ingest.de.sentry.io/123/extra",
        ] {
            XCTAssertFalse(
                CrashReportingConfiguration.isAllowedDSN(rejected),
                rejected
            )
        }
    }

    func testSessionsAreEnabledOnlyWithCrashConsent() {
        XCTAssertFalse(SentryCrashReporter.sessionsEnabled(for: []))
        XCTAssertFalse(
            SentryCrashReporter.sessionsEnabled(for: [.basicDiagnostics])
        )
        XCTAssertFalse(
            SentryCrashReporter.sessionsEnabled(for: [.performance])
        )
        XCTAssertTrue(SentryCrashReporter.sessionsEnabled(for: [.crash]))
        XCTAssertTrue(
            SentryCrashReporter.sessionsEnabled(
                for: [.crash, .basicDiagnostics, .performance]
            )
        )
    }

    func testRevocationPurgesDedicatedLocalCache() throws {
        let defaults = makeDefaults()
        AppPrivacyPreference.migrateIfNeeded(in: defaults)
        let root = try makeTemporaryTestDirectory(prefix: "SentryRevocation")
        let cache = root.appendingPathComponent("Sentry", isDirectory: true)
        let oldEnvelope = cache.appendingPathComponent("old-envelope")
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldEnvelope)

        NetworkSpyURLProtocol.reset()
        let sessionConfiguration = URLSessionConfiguration.ephemeral
        sessionConfiguration.protocolClasses = [NetworkSpyURLProtocol.self]
        let reporter = SentryCrashReporter {
            URLSession(configuration: sessionConfiguration)
        }
        let configuration = CrashReportingConfiguration(
            dsn: "https://public@o1.ingest.de.sentry.io/1",
            environment: "qa",
            releaseName: "dev.speechlens.SpeechLens@1.0+1",
            distribution: "1",
            cacheDirectoryURL: cache
        )
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: configuration,
            environment: testEnvironment,
            reporter: reporter
        )

        coordinator.start(initialReport: nil)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEnvelope.path))
        XCTAssertEqual(NetworkSpyURLProtocol.requestCount, 0)

        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        notify(defaults)
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldEnvelope)
        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEnvelope.path))
        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEnvelope.path))

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
    }

    func testPendingCrashCacheSurvivesRelaunchWhenModeIsUnchanged() throws {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let root = try makeTemporaryTestDirectory(prefix: "SentryPendingCrash")
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        let crashCache = root.appendingPathComponent("crash", isDirectory: true)
        let envelope = crashCache.appendingPathComponent("pending-envelope")
        try FileManager.default.createDirectory(
            at: crashCache,
            withIntermediateDirectories: true
        )
        try Data("pending".utf8).write(to: envelope)
        let reporter = RecordingCrashReporter()
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: configuration(cacheRoot: root),
            environment: testEnvironment,
            reporter: reporter
        )

        coordinator.start(initialReport: nil)

        XCTAssertTrue(FileManager.default.fileExists(atPath: envelope.path))
        XCTAssertEqual(reporter.starts.last?.configuration.cacheDirectoryURL, crashCache)
    }

    func testLegacyCacheIsPurgedWhenModeDirectoriesAreIntroduced() throws {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        let root = try makeTemporaryTestDirectory(prefix: "SentryLegacyCache")
        let legacyEnvelope = root.appendingPathComponent("legacy-envelope")
        let crashCache = root.appendingPathComponent("crash", isDirectory: true)
        let currentEnvelope = crashCache.appendingPathComponent("current-envelope")
        try FileManager.default.createDirectory(
            at: crashCache,
            withIntermediateDirectories: true
        )
        try Data("legacy".utf8).write(to: legacyEnvelope)
        try Data("current".utf8).write(to: currentEnvelope)
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: configuration(cacheRoot: root),
            environment: testEnvironment,
            reporter: RecordingCrashReporter()
        )

        coordinator.start(initialReport: nil)

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyEnvelope.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: currentEnvelope.path))
    }

    private func makeCoordinator(
        defaults: UserDefaults,
        reporter: RecordingCrashReporter
    ) -> AppTelemetryCoordinator {
        AppTelemetryCoordinator(
            defaults: defaults,
            configuration: testConfiguration,
            environment: testEnvironment,
            reporter: reporter
        )
    }

    private func makeRecorder() throws -> AppDiagnosticRecorder {
        let root = try makeTemporaryTestDirectory(prefix: "CrashContext")
        return AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: root.appendingPathComponent("latest-operation.json")
            ),
            environment: testEnvironment
        )
    }

    private func acceptOnboarding(
        reliability: Bool,
        defaults: UserDefaults
    ) {
        AppOnboardingPreference.accept(
            reliabilityReporting: reliability,
            enhancementPerformance: false,
            modelIsReady: true,
            in: defaults,
            startModelDownload: {}
        )
    }

    private func notify(_ defaults: UserDefaults) {
        NotificationCenter.default.post(
            name: UserDefaults.didChangeNotification,
            object: defaults
        )
    }

    private func makeDefaults() -> UserDefaults {
        let suite = "AppCrashReportingTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    private var testConfiguration: CrashReportingConfiguration {
        configuration(
            cacheRoot: FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
        )
    }

    private func configuration(cacheRoot: URL) -> CrashReportingConfiguration {
        CrashReportingConfiguration(
            dsn: "https://public@o1.ingest.de.sentry.io/1",
            environment: "qa",
            releaseName: "dev.speechlens.SpeechLens@1.0+1",
            distribution: "1",
            cacheDirectoryURL: cacheRoot
        )
    }

    private var testEnvironment: DiagnosticEnvironment {
        DiagnosticEnvironment(
            appVersion: "1.0",
            appBuild: "1",
            macOSVersion: "14.6.1",
            hardwareModel: "Mac14,5",
            processorCount: 8,
            physicalMemoryGiB: 16,
            hardware: DiagnosticHardwareFacts(
                cpuPhysicalCores: 8,
                cpuLogicalCores: 8,
                cpuPerformanceCores: 4,
                cpuEfficiencyCores: 4,
                gpuName: "Apple M2",
                gpuCoreCount: 10,
                gpuHasUnifiedMemory: true,
                gpuMaxWorkingSetGiB: 12
            )
        )
    }
}

@MainActor
private final class RecordingCrashReporter: AppTelemetryReporting {
    struct Start {
        let configuration: CrashReportingConfiguration
        let environment: CrashEnvironmentContext
        let operation: CrashOperationContext?
        let capabilities: TelemetryCapabilities
        let userID: String
    }

    private(set) var starts = [Start]()
    private(set) var updates = [CrashOperationContext?]()
    private(set) var activities = [DailyActivityRecord]()
    private(set) var stopCount = 0

    func start(
        configuration: CrashReportingConfiguration,
        environment: CrashEnvironmentContext,
        context: CrashOperationContext?,
        capabilities: TelemetryCapabilities,
        userID: String
    ) {
        starts.append(Start(
            configuration: configuration,
            environment: environment,
            operation: context,
            capabilities: capabilities,
            userID: userID
        ))
    }

    func update(context: CrashOperationContext?) {
        updates.append(context)
    }

    func submit(_ record: EnhancementPerformanceRecord) {}
    func submit(_ record: DailyActivityRecord) {
        activities.append(record)
    }

    func stopAndPurge(cacheDirectoryURL: URL) {
        stopCount += 1
    }
}

private final class NetworkSpyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0

    static var requestCount: Int {
        lock.withLock { count }
    }

    static func reset() {
        lock.withLock { count = 0 }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock { Self.count += 1 }
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.notConnectedToInternet)
        )
    }

    override func stopLoading() {}
}
