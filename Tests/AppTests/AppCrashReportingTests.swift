// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation
import XCTest
@testable import App

@MainActor
final class AppCrashReportingTests: XCTestCase {
    func testAllConsentCombinationsSelectExpectedMode() async {
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
                    await coordinator.waitForConsentTransition()

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
                    await coordinator.waitForConsentTransition()
                }
            }
        }
    }

    func testOnboardingAcceptanceIsRequiredBeforeDefaultOnConsentStartsReporter() async {
        let defaults = makeDefaults()
        AppPrivacyPreference.migrateIfNeeded(in: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()

        XCTAssertTrue(defaults.bool(forKey: AppPrivacyPreference.crashReportingKey))
        XCTAssertTrue(AppOnboardingPreference.isRequired(in: defaults))
        XCTAssertTrue(reporter.starts.isEmpty)
        XCTAssertEqual(reporter.stopCount, 0)

        acceptOnboarding(reliability: true, defaults: defaults)
        notify(defaults)
        await coordinator.waitForConsentTransition()

        XCTAssertEqual(reporter.starts.count, 1)
    }

    func testAcceptedCrashConsentIsIndependentFromBasicDiagnostics() async {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()

        XCTAssertEqual(reporter.starts.count, 1)
    }

    func testLiveRevocationAndReenableDoNotRestoreTerminalOperationContext() async throws {
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
        await coordinator.waitForConsentTransition()

        XCTAssertNotNil(reporter.starts.last?.operation)
        let retiredCache = try XCTUnwrap(reporter.starts.last?.configuration.cacheDirectoryURL)
        recorder.cancelCurrentOperation()
        coordinator.update(report: recorder.latestReport())
        XCTAssertNil(reporter.updates.last!)

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        XCTAssertEqual(reporter.stopCount, 1)
        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        XCTAssertEqual(reporter.starts.count, 1)
        await coordinator.waitForConsentTransition()

        XCTAssertEqual(reporter.stopCount, 1)
        XCTAssertEqual(reporter.starts.count, 2)
        XCTAssertNil(reporter.starts.last?.operation)
        XCTAssertNotEqual(reporter.starts.last?.configuration.cacheDirectoryURL, retiredCache)
    }

    func testReliabilityToggleSkipsIntermediateCapabilityMode() async {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: false, defaults: defaults)
        defaults.set(true, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)
        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()

        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        defaults.set(true, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        notify(defaults)

        XCTAssertEqual(reporter.stopCount, 1)
        XCTAssertEqual(reporter.starts.map(\.capabilities), [.performance])
        await coordinator.waitForConsentTransition()
        XCTAssertEqual(reporter.starts.map(\.capabilities), [
            .performance, [.crash, .basicDiagnostics, .performance],
        ])
    }

    func testIdleStartAlwaysCarriesSanitizedEnvironmentContext() async {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()

        let environment = reporter.starts.last?.environment.sentryValues
        XCTAssertEqual(environment?["hardware_model"] as? String, "Mac14,5")
        XCTAssertEqual(environment?["macos_version"] as? String, "14.6.1")
        XCTAssertNil(reporter.starts.last?.operation)
    }

    func testConsentEpochUserIDPersistsAcrossModeChangeAndRotatesAfterFullRevocation() async {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = makeCoordinator(defaults: defaults, reporter: reporter)

        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()
        let firstID = reporter.starts.last?.userID

        defaults.set(true, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        notify(defaults)
        await coordinator.waitForConsentTransition()
        XCTAssertEqual(reporter.starts.last?.userID, firstID)

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        defaults.set(false, forKey: AppPrivacyPreference.enhancementPerformanceKey)
        notify(defaults)
        await coordinator.waitForConsentTransition()
        XCTAssertNil(defaults.string(forKey: "telemetry.consentEpochUserID"))

        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        defaults.set(true, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        notify(defaults)
        await coordinator.waitForConsentTransition()
        XCTAssertNotEqual(reporter.starts.last?.userID, firstID)
    }

    func testDailyActivityEmitsOncePerUTCDay() async {
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
        await coordinator.waitForConsentTransition()
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

    func testMalformedOrMissingConfigurationNeverStartsReporter() async throws {
        let defaults = makeDefaults()
        acceptOnboarding(reliability: true, defaults: defaults)
        let reporter = RecordingCrashReporter()
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: nil,
            cacheDirectoryURL: try makeTemporaryTestDirectory(prefix: "SentryNoConfiguration"),
            environment: testEnvironment,
            reporter: reporter
        )

        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()

        XCTAssertTrue(reporter.starts.isEmpty)
        XCTAssertEqual(reporter.stopCount, 0)
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

    func testRevocationPurgesDedicatedLocalCache() async throws {
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
        await coordinator.waitForConsentTransition()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEnvelope.path))
        XCTAssertEqual(NetworkSpyURLProtocol.requestCount, 0)

        acceptOnboarding(reliability: true, defaults: defaults)
        defaults.set(false, forKey: AppPrivacyPreference.basicDiagnosticsKey)
        notify(defaults)
        await coordinator.waitForConsentTransition()
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        try Data("old".utf8).write(to: oldEnvelope)
        // Give the SDK's crash-cache worker time to enter its polling wait.
        try await Task.sleep(for: .milliseconds(50))
        let shutdown = ContinuousClock().measure {
            defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
            notify(defaults)
        }
        XCTAssertLessThan(shutdown, .milliseconds(750))
        await coordinator.waitForConsentTransition()
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEnvelope.path))
        defaults.set(true, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        await coordinator.waitForConsentTransition()

        XCTAssertFalse(FileManager.default.fileExists(atPath: oldEnvelope.path))

        defaults.set(false, forKey: AppPrivacyPreference.crashReportingKey)
        notify(defaults)
        await coordinator.waitForConsentTransition()
    }

    func testRetiredTransportRejectsLateTasksAfterReenable() async throws {
        NetworkSpyURLProtocol.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NetworkSpyURLProtocol.self]
        let retired = SentryConsentTransport(networkSession: URLSession(configuration: configuration))
        retired.revoke()
        let current = SentryConsentTransport(networkSession: URLSession(configuration: configuration))
        defer { current.revoke() }

        var request = URLRequest(url: try XCTUnwrap(URL(string: "https://example.invalid/envelope/")))
        request.httpMethod = "POST"
        request.httpBody = Data("envelope".utf8)

        do {
            _ = try await retired.sdkSession.data(for: request)
            XCTFail("The retired transport accepted a late request")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .cancelled)
        }
        XCTAssertEqual(NetworkSpyURLProtocol.requestCount, 0)

        let (data, response) = try await current.sdkSession.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        XCTAssertEqual(data, request.httpBody)
        XCTAssertEqual(NetworkSpyURLProtocol.requestCount, 1)
        XCTAssertEqual(NetworkSpyURLProtocol.lastRequest?.httpMethod, request.httpMethod)
        XCTAssertEqual(NetworkSpyURLProtocol.lastRequest?.url, request.url)
        XCTAssertNil(NetworkSpyURLProtocol.lastRequest?.value(forHTTPHeaderField: "X-SpeechLens-Local-Sentry-Route"))
    }

    func testLateCacheWritesCannotRejoinCurrentClientAfterRevocation() throws {
        let mode = try makeTemporaryTestDirectory(prefix: "SentryCacheGeneration")
            .appendingPathComponent("crash", isDirectory: true)
        try FileManager.default.createDirectory(at: mode, withIntermediateDirectories: true)
        let legacyEnvelope = mode.appendingPathComponent("existing-envelope")
        try Data("pending".utf8).write(to: legacyEnvelope)

        let retired = SentryCacheGeneration.directory(in: mode)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: retired.appendingPathComponent(legacyEnvelope.lastPathComponent).path
        ))
        XCTAssertEqual(SentryCacheGeneration.directory(in: mode), retired)

        try FileManager.default.removeItem(at: mode)
        XCTAssertFalse(FileManager.default.fileExists(atPath: mode.path))
        try FileManager.default.createDirectory(at: retired, withIntermediateDirectories: true)
        let lateEnvelope = retired.appendingPathComponent("late-envelope")
        try Data("retired".utf8).write(to: lateEnvelope)

        let current = SentryCacheGeneration.directory(in: mode)
        XCTAssertNotEqual(current, retired)
        XCTAssertFalse(FileManager.default.fileExists(atPath: lateEnvelope.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: current.path), [])
        XCTAssertEqual(SentryCacheGeneration.directory(in: mode), current)
    }

    func testPendingCrashCacheSurvivesRelaunchWhenModeIsUnchanged() async throws {
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
        await coordinator.waitForConsentTransition()

        let activeCache = try XCTUnwrap(reporter.starts.last?.configuration.cacheDirectoryURL)
        let pendingEnvelope = activeCache.appendingPathComponent(envelope.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingEnvelope.path))
        XCTAssertEqual(activeCache.deletingLastPathComponent(), crashCache)
    }

    func testLegacyCacheIsPurgedWhenModeDirectoriesAreIntroduced() async throws {
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
        let reporter = RecordingCrashReporter()
        let coordinator = AppTelemetryCoordinator(
            defaults: defaults,
            configuration: configuration(cacheRoot: root),
            environment: testEnvironment,
            reporter: reporter
        )

        coordinator.start(initialReport: nil)
        await coordinator.waitForConsentTransition()

        XCTAssertFalse(FileManager.default.fileExists(atPath: legacyEnvelope.path))
        let activeCache = try XCTUnwrap(reporter.starts.last?.configuration.cacheDirectoryURL)
        let pendingEnvelope = activeCache.appendingPathComponent(currentEnvelope.lastPathComponent)
        XCTAssertTrue(FileManager.default.fileExists(atPath: pendingEnvelope.path))
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

    func stop() {
        stopCount += 1
    }
}

private final class NetworkSpyURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var requestSeen: URLRequest?

    static var requestCount: Int {
        lock.withLock { count }
    }

    static var lastRequest: URLRequest? {
        lock.withLock { requestSeen }
    }

    static func reset() {
        lock.withLock {
            count = 0
            requestSeen = nil
        }
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        Self.lock.withLock {
            Self.count += 1
            Self.requestSeen = request
        }
        if let url = request.url, url.host == "example.invalid",
           let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil) {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: requestBody())
            client?.urlProtocolDidFinishLoading(self)
            return
        }
        client?.urlProtocol(
            self,
            didFailWithError: URLError(.notConnectedToInternet)
        )
    }

    override func stopLoading() {}

    private func requestBody() -> Data {
        guard let stream = request.httpBodyStream else { return request.httpBody ?? Data() }
        stream.open()
        defer { stream.close() }
        var body = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while case let count = stream.read(&buffer, maxLength: buffer.count), count > 0 {
            body.append(contentsOf: buffer.prefix(count))
        }
        return body
    }
}
