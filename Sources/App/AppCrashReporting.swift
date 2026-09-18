// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation

struct CrashEnvironmentContext: Equatable, Sendable {
    static let eventSchemaVersion = 1
    static let sentryContextKey = "speechlens_environment"
    static let allowedFieldNames: Set<String> = [
        "event_schema_version",
        "app_version",
        "app_build",
        "macos_version",
        "hardware_model",
        "processor_count",
        "physical_memory_gib",
        "cpu_physical_cores",
        "cpu_logical_cores",
        "cpu_performance_cores",
        "cpu_efficiency_cores",
        "gpu_name",
        "gpu_core_count",
        "gpu_has_unified_memory",
        "gpu_max_working_set_gib",
    ]

    let environment: DiagnosticEnvironment

    var sentryValues: [String: Any] {
        var values: [String: Any] = [
            "event_schema_version": Self.eventSchemaVersion,
            "app_version": environment.appVersion,
            "app_build": environment.appBuild,
            "macos_version": environment.macOSVersion,
            "hardware_model": environment.hardwareModel,
            "processor_count": environment.processorCount,
            "physical_memory_gib": environment.physicalMemoryGiB,
        ]
        if let hardware = environment.hardware {
            values["cpu_physical_cores"] = hardware.cpuPhysicalCores
            values["cpu_logical_cores"] = hardware.cpuLogicalCores
            values["cpu_performance_cores"] = hardware.cpuPerformanceCores
            values["cpu_efficiency_cores"] = hardware.cpuEfficiencyCores
            values["gpu_name"] = hardware.gpuName
            values["gpu_core_count"] = hardware.gpuCoreCount
            values["gpu_has_unified_memory"] = hardware.gpuHasUnifiedMemory
            values["gpu_max_working_set_gib"] = hardware.gpuMaxWorkingSetGiB
        }
        return values
    }

    static func sanitize(_ values: [String: Any]) -> [String: Any] {
        sanitizeCrashContext(values, allowedFields: allowedFieldNames)
    }
}

struct CrashOperationContext: Equatable, Sendable {
    static let eventSchemaVersion = 1
    static let sentryContextKey = "speechlens_operation"
    static let allowedFieldNames: Set<String> = [
        "event_schema_version",
        "operation",
        "phase",
        "model_artifact_version",
        "model_selection",
        "processing_profile",
        "chunk_seconds",
        "overlap_portion",
    ]

    let operation: DiagnosticOperation
    let phase: DiagnosticPhase
    let model: DiagnosticModel
    let settings: DiagnosticSettings?

    init?(report: DiagnosticReport?) {
        guard let report, report.outcome == .inProgress else { return nil }
        operation = report.operation
        phase = report.phase
        model = report.model
        settings = report.settings
    }

    var sentryValues: [String: Any] {
        var values: [String: Any] = [
            "event_schema_version": Self.eventSchemaVersion,
            "operation": operation.rawValue,
            "phase": phase.rawValue,
            "model_artifact_version": model.artifactVersion,
            "model_selection": model.selection.rawValue,
        ]
        if let settings {
            values["processing_profile"] = settings.profile
            values["chunk_seconds"] = settings.chunkSeconds
            values["overlap_portion"] = settings.overlapPortion
        }
        return values
    }

    static func sanitize(_ values: [String: Any]) -> [String: Any] {
        sanitizeCrashContext(values, allowedFields: allowedFieldNames)
    }
}

private func sanitizeCrashContext(
    _ values: [String: Any],
    allowedFields: Set<String>
) -> [String: Any] {
    values.filter { key, value in
        guard allowedFields.contains(key) else { return false }
        if let value = value as? String {
            return value.utf8.count <= 128
                && !value.contains("/")
                && !value.contains("\\")
                && !value.contains("\n")
                && !value.contains("\r")
                && !value.contains("://")
        }
        return value is NSNumber || value is Int || value is Double || value is Bool
    }
}

struct CrashReportingConfiguration: Equatable, Sendable {
    let dsn: String
    let environment: String
    let releaseName: String
    let distribution: String
    let cacheDirectoryURL: URL

    static func load(
        bundle: Bundle = .main,
        fileManager: FileManager = .default
    ) -> Self? {
        guard
            let dsn = nonemptyString(bundle, key: "SpeechLensSentryDSN"),
            isAllowedDSN(dsn),
            let environment = nonemptyString(
                bundle,
                key: "SpeechLensSentryEnvironment"
            ),
            ["development", "qa", "production"].contains(environment),
            let bundleID = bundle.bundleIdentifier,
            let version = bundle.object(
                forInfoDictionaryKey: "CFBundleShortVersionString"
            ) as? String,
            let build = bundle.object(
                forInfoDictionaryKey: "CFBundleVersion"
            ) as? String
        else { return nil }

        let cacheURL = defaultCacheDirectoryURL(fileManager: fileManager)
        return Self(
            dsn: dsn,
            environment: environment,
            releaseName: "\(bundleID)@\(version)+\(build)",
            distribution: build,
            cacheDirectoryURL: cacheURL
        )
    }

    static func defaultCacheDirectoryURL(
        fileManager: FileManager = .default
    ) -> URL {
        let cacheBase = fileManager.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first ?? fileManager.temporaryDirectory
        return cacheBase
            .appendingPathComponent("SpeechLens", isDirectory: true)
            .appendingPathComponent("Sentry", isDirectory: true)
    }

    private static func nonemptyString(_ bundle: Bundle, key: String) -> String? {
        guard
            let value = bundle.object(forInfoDictionaryKey: key) as? String,
            !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
            !value.contains("$(")
        else { return nil }
        return value
    }

    static func isAllowedDSN(_ value: String) -> Bool {
        guard
            let components = URLComponents(string: value),
            components.scheme == "https",
            components.user?.isEmpty == false,
            let host = components.host?.lowercased(),
            host == "ingest.de.sentry.io"
                || host.hasSuffix(".ingest.de.sentry.io"),
            components.port == nil,
            components.password == nil,
            components.query == nil,
            components.fragment == nil,
            let projectID = components.path.split(separator: "/").only,
            projectID.allSatisfy(\.isNumber)
        else { return false }
        return true
    }
}

private extension Collection {
    var only: Element? {
        count == 1 ? first : nil
    }
}

struct TelemetryCapabilities: OptionSet, Sendable, Equatable {
    let rawValue: UInt8

    static let crash = Self(rawValue: 1 << 0)
    static let performance = Self(rawValue: 1 << 1)
    static let basicDiagnostics = Self(rawValue: 1 << 2)
}

struct TelemetryCapabilityMode: Sendable, Equatable {
    static let allModes = (1 ... 7).compactMap {
        TelemetryCapabilityMode(
            TelemetryCapabilities(rawValue: UInt8($0))
        )
    }

    init?(_ capabilities: TelemetryCapabilities) {
        guard !capabilities.isEmpty, capabilities.rawValue & ~UInt8(0b111) == 0
        else { return nil }
        self.capabilities = capabilities
    }

    let capabilities: TelemetryCapabilities

    var cacheDirectoryName: String {
        [
            capabilities.contains(.crash) ? "crash" : nil,
            capabilities.contains(.basicDiagnostics) ? "basic" : nil,
            capabilities.contains(.performance) ? "performance" : nil,
        ].compactMap { $0 }.joined(separator: "-")
    }
}

@MainActor
protocol AppTelemetryReporting: AnyObject {
    func start(
        configuration: CrashReportingConfiguration,
        environment: CrashEnvironmentContext,
        context: CrashOperationContext?,
        capabilities: TelemetryCapabilities,
        userID: String
    )
    func update(context: CrashOperationContext?)
    func submit(_ record: EnhancementPerformanceRecord)
    func submit(_ record: DailyActivityRecord)
    func stopAndPurge(cacheDirectoryURL: URL)
}

@MainActor
final class AppTelemetryCoordinator: AppEnhancementPerformanceReporting {
    private static let userIDKey = "telemetry.consentEpochUserID"
    private static let dailyActivityKey = "telemetry.lastDailyActivity"

    private let defaults: UserDefaults
    private let configuration: CrashReportingConfiguration?
    private let cacheDirectoryURL: URL
    private let environment: CrashEnvironmentContext
    private let reporter: any AppTelemetryReporting
    private let fileManager: FileManager
    private let now: () -> Date
    private let makeUserID: () -> UUID
    private var observer: NSObjectProtocol?
    private var latestContext: CrashOperationContext?
    private var activeMode: TelemetryCapabilityMode?
    private var activeUserID: String?
    private var hasAppliedConsent = false

    init(
        defaults: UserDefaults = .standard,
        configuration: CrashReportingConfiguration? = .load(),
        cacheDirectoryURL: URL = CrashReportingConfiguration
            .defaultCacheDirectoryURL(),
        environment: DiagnosticEnvironment = .current(),
        reporter: any AppTelemetryReporting,
        fileManager: FileManager = .default,
        now: @escaping () -> Date = Date.init,
        makeUserID: @escaping () -> UUID = UUID.init
    ) {
        self.defaults = defaults
        self.configuration = configuration
        self.cacheDirectoryURL = configuration?.cacheDirectoryURL
            ?? cacheDirectoryURL
        self.environment = CrashEnvironmentContext(environment: environment)
        self.reporter = reporter
        self.fileManager = fileManager
        self.now = now
        self.makeUserID = makeUserID
    }

    func start(initialReport: DiagnosticReport?) {
        latestContext = CrashOperationContext(report: initialReport)
        observer = NotificationCenter.default.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: defaults,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.applyConsent()
            }
        }
        applyConsent(isInitial: true)
        recordDailyActivityIfNeeded()
    }

    func update(report: DiagnosticReport?) {
        latestContext = CrashOperationContext(report: report)
        if activeMode != nil {
            reporter.update(context: latestContext)
        }
        recordDailyActivityIfNeeded()
    }

    func stop() {
        if let activeMode {
            reporter.stopAndPurge(
                cacheDirectoryURL: cacheURL(for: activeMode)
            )
        }
        activeMode = nil
        activeUserID = nil
        purgeAllCaches()
        if let observer {
            NotificationCenter.default.removeObserver(observer)
            self.observer = nil
        }
    }

    func submit(_ record: EnhancementPerformanceRecord) {
        guard performanceConsentEnabled,
              activeMode?.capabilities.contains(.performance) == true
        else { return }
        reporter.submit(record)
    }

    func recordDailyActivityIfNeeded() {
        guard
            basicDiagnosticsConsentEnabled,
            activeMode?.capabilities.contains(.basicDiagnostics) == true,
            let userID = activeUserID,
            let record = DailyActivityRecord(environment: environment.environment)
        else { return }
        let marker = "\(userID):\(Self.utcDay(now()))"
        guard defaults.string(forKey: Self.dailyActivityKey) != marker else {
            return
        }
        defaults.set(marker, forKey: Self.dailyActivityKey)
        reporter.submit(record)
    }

    private var onboardingAccepted: Bool {
        !AppOnboardingPreference.isRequired(in: defaults)
    }

    private var crashConsentEnabled: Bool {
        guard onboardingAccepted else { return false }
        if let value = defaults.object(
            forKey: AppPrivacyPreference.crashReportingKey
        ) as? Bool {
            return value
        }
        return AppPrivacyPreference.crashReportingDefault
    }

    private var performanceConsentEnabled: Bool {
        guard onboardingAccepted else { return false }
        if let value = defaults.object(
            forKey: AppPrivacyPreference.enhancementPerformanceKey
        ) as? Bool {
            return value
        }
        return AppPrivacyPreference.enhancementPerformanceDefault
    }

    private var basicDiagnosticsConsentEnabled: Bool {
        guard onboardingAccepted else { return false }
        if let value = defaults.object(
            forKey: AppPrivacyPreference.basicDiagnosticsKey
        ) as? Bool {
            return value
        }
        return AppPrivacyPreference.basicDiagnosticsDefault
    }

    private var authorizedCapabilities: TelemetryCapabilities {
        var capabilities: TelemetryCapabilities = []
        if crashConsentEnabled { capabilities.insert(.crash) }
        if performanceConsentEnabled { capabilities.insert(.performance) }
        if basicDiagnosticsConsentEnabled {
            capabilities.insert(.basicDiagnostics)
        }
        return capabilities
    }

    private func applyConsent(isInitial: Bool = false) {
        let requestedMode = TelemetryCapabilityMode(authorizedCapabilities)
        guard let configuration, let requestedMode else {
            if let activeMode {
                reporter.stopAndPurge(
                    cacheDirectoryURL: cacheURL(for: activeMode)
                )
            } else if !hasAppliedConsent {
                reporter.stopAndPurge(cacheDirectoryURL: cacheDirectoryURL)
                purgeAllCaches()
            }
            activeMode = nil
            activeUserID = nil
            purgeAllCaches()
            if authorizedCapabilities.isEmpty {
                if defaults.object(forKey: Self.userIDKey) != nil {
                    defaults.removeObject(forKey: Self.userIDKey)
                }
                if defaults.object(forKey: Self.dailyActivityKey) != nil {
                    defaults.removeObject(forKey: Self.dailyActivityKey)
                }
            }
            hasAppliedConsent = true
            return
        }

        if isInitial {
            purgeLegacyCacheContents()
            purgeCaches(except: requestedMode)
        }
        let userID = existingOrNewUserID()
        guard activeMode != requestedMode else { return }
        if let retiredMode = activeMode {
            reporter.stopAndPurge(
                cacheDirectoryURL: cacheURL(for: retiredMode)
            )
            // A capability change starts from an empty current-mode cache too,
            // preventing historical replay across policy identities.
            try? fileManager.removeItem(at: cacheURL(for: requestedMode))
        }
        let modeConfiguration = CrashReportingConfiguration(
            dsn: configuration.dsn,
            environment: configuration.environment,
            releaseName: configuration.releaseName,
            distribution: configuration.distribution,
            cacheDirectoryURL: cacheURL(for: requestedMode)
        )
        reporter.start(
            configuration: modeConfiguration,
            environment: environment,
            context: latestContext,
            capabilities: requestedMode.capabilities,
            userID: userID
        )
        activeMode = requestedMode
        activeUserID = userID
        hasAppliedConsent = true
        recordDailyActivityIfNeeded()
    }

    private func cacheURL(for mode: TelemetryCapabilityMode) -> URL {
        cacheDirectoryURL.appendingPathComponent(
            mode.cacheDirectoryName,
            isDirectory: true
        )
    }

    private func purgeCaches(except retainedMode: TelemetryCapabilityMode) {
        for mode in TelemetryCapabilityMode.allModes where mode != retainedMode {
            try? fileManager.removeItem(at: cacheURL(for: mode))
        }
    }

    private func purgeAllCaches() {
        for mode in TelemetryCapabilityMode.allModes {
            try? fileManager.removeItem(at: cacheURL(for: mode))
        }
        purgeLegacyCacheContents()
    }

    private func purgeLegacyCacheContents() {
        guard let contents = try? fileManager.contentsOfDirectory(
            at: cacheDirectoryURL,
            includingPropertiesForKeys: nil
        ) else { return }
        let modeNames = Set(
            TelemetryCapabilityMode.allModes.map(\.cacheDirectoryName)
        )
        for url in contents where !modeNames.contains(url.lastPathComponent) {
            try? fileManager.removeItem(at: url)
        }
    }

    private func existingOrNewUserID() -> String {
        if let value = defaults.string(forKey: Self.userIDKey),
           UUID(uuidString: value) != nil {
            return value
        }
        let value = makeUserID().uuidString.lowercased()
        defaults.set(value, forKey: Self.userIDKey)
        return value
    }

    private static func utcDay(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0
        )
    }
}
