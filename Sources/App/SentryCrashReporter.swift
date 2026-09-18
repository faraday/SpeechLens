// SPDX-License-Identifier: Apache-2.0

import Foundation
import Sentry

@MainActor
final class SentryCrashReporter: AppTelemetryReporting {
    private var consentGate = TelemetryConsentGate()
    private var isStarted = false
    private let makeURLSession: @MainActor () -> URLSession
    private var activeURLSession: URLSession?

    init(
        makeURLSession: @escaping @MainActor () -> URLSession = {
            URLSession(configuration: .ephemeral)
        }
    ) {
        self.makeURLSession = makeURLSession
    }

    func start(
        configuration: CrashReportingConfiguration,
        environment: CrashEnvironmentContext,
        context: CrashOperationContext?,
        capabilities: TelemetryCapabilities,
        userID: String
    ) {
        guard !isStarted else {
            update(context: context)
            return
        }

        let gate = TelemetryConsentGate()
        gate.setCapabilities(capabilities)
        consentGate = gate
        let transportSession = makeURLSession()
        activeURLSession = transportSession
        SentrySDK.start { options in
            Self.configure(
                options,
                configuration: configuration,
                consentGate: gate,
                urlSession: transportSession,
                capabilities: capabilities,
                userID: userID
            )
        }
        isStarted = true
        SentrySDK.configureScope { scope in
            scope.setContext(
                value: environment.sentryValues,
                key: CrashEnvironmentContext.sentryContextKey
            )
        }
        update(context: context)
    }

    func update(context: CrashOperationContext?) {
        guard isStarted else { return }
        SentrySDK.configureScope { scope in
            scope.setTags(nil)
            scope.setExtras(nil)
            scope.clearBreadcrumbs()
            scope.clearAttachments()
            if let context {
                scope.setContext(
                    value: context.sentryValues,
                    key: CrashOperationContext.sentryContextKey
                )
            } else {
                scope.removeContext(
                    key: CrashOperationContext.sentryContextKey
                )
            }
        }
    }

    func submit(_ record: EnhancementPerformanceRecord) {
        guard
            isStarted,
            consentGate.capabilities.contains(.performance),
            let payload = record.validatedPayload
        else {
            return
        }
        let context = TransactionContext(
            name: "media_enhancement",
            operation: "speechlens.enhancement",
            sampled: .yes,
            sampleRate: NSNumber(value: 1.0),
            sampleRand: nil
        )
        let transaction = SentrySDK.startTransaction(
            transactionContext: context,
            bindToScope: false
        )
        // Private pre-send discriminator. The sanitizer removes it from the
        // outbound payload after verifying this exact adapter-created root.
        transaction.setTag(
            value: "speechlens.enhancement/v1",
            key: "_speechlens_transaction_contract"
        )
        for (name, value) in payload.measurements {
            transaction.setMeasurement(
                name: name,
                value: NSNumber(value: value)
            )
        }
        for (name, value) in payload.dimensions {
            transaction.setTag(value: value, key: name)
        }
        transaction.finish(status: .ok)
    }

    func submit(_ record: DailyActivityRecord) {
        guard
            isStarted,
            consentGate.capabilities.contains(.basicDiagnostics)
        else { return }
        let context = TransactionContext(
            name: "app_daily_active",
            operation: "speechlens.activity",
            sampled: .yes,
            sampleRate: NSNumber(value: 1.0),
            sampleRand: nil
        )
        let transaction = SentrySDK.startTransaction(
            transactionContext: context,
            bindToScope: false
        )
        transaction.setTag(
            value: "speechlens.activity/v1",
            key: "_speechlens_transaction_contract"
        )
        for (name, value) in record.dimensions {
            transaction.setTag(value: value, key: name)
        }
        transaction.finish(status: .ok)
    }

    func stopAndPurge(cacheDirectoryURL: URL) {
        consentGate.setCapabilities([])
        // SentrySDK.close() always attempts a flush, even with a zero timeout.
        // Invalidate our owned transport first so cached envelopes cannot be
        // sent by that flush or by a superseded client after re-enabling.
        activeURLSession?.invalidateAndCancel()
        activeURLSession = nil
        if isStarted {
            SentrySDK.configureScope { scope in
                scope.clear()
                scope.clearAttachments()
            }
            SentrySDK.close()
            isStarted = false
        }
        try? FileManager.default.removeItem(at: cacheDirectoryURL)
    }

    nonisolated private static func configure(
        _ options: Options,
        configuration: CrashReportingConfiguration,
        consentGate: TelemetryConsentGate,
        urlSession: URLSession?,
        capabilities: TelemetryCapabilities,
        userID: String
    ) {
        options.dsn = configuration.dsn
        options.environment = configuration.environment
        options.releaseName = configuration.releaseName
        options.dist = configuration.distribution
        options.cacheDirectoryPath = configuration.cacheDirectoryURL.path
        options.urlSession = urlSession
        options.maxCacheItems = 5
        options.shutdownTimeInterval = 0

        options.enabled = true
        options.enableCrashHandler = capabilities.contains(.crash)
        options.enableUncaughtNSExceptionReporting = false
        options.enableSigtermReporting = false
        options.enableMemoryIntrospection = false
        options.sendDefaultPii = false
        options.sendClientReports = false

        options.enableAutoSessionTracking = sessionsEnabled(for: capabilities)
        options.initialScope = { scope in
            scope.setUser(sentryUser(userID))
            return scope
        }
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.maxBreadcrumbs = 0
        options.beforeBreadcrumb = { _ in nil }

        options.enableLogs = false
        options.enableAppHangTracking = false
        options.enableWatchdogTerminationTracking = false
        options.enableMetricKit = false
        options.enableMetricKitRawPayload = false

        options.enableSwizzling = false
        options.enableCaptureFailedRequests = false
        options.enableAutoPerformanceTracing = false
        options.enableNetworkTracking = false
        options.enableFileIOTracing = false
        options.enableDataSwizzling = false
        options.enableFileManagerSwizzling = false
        options.enableCoreDataTracing = false
        options.tracesSampleRate = 0
        options.tracesSampler = nil
        options.configureProfiling = nil
        options.enablePersistingTracesWhenCrashing = false
        options.swiftAsyncStacktraces = false
        options.enableMetrics = false
        options.beforeSendSpan = { _ in nil }

        options.beforeSend = { event in
            if consentGate.capabilities.contains(.crash),
               isNativeCrash(event) {
                return sanitizeCrash(event)
            }
            if consentGate.capabilities.contains(.performance),
               isPerformanceTransaction(event) {
                return sanitizePerformance(event)
            }
            if consentGate.capabilities.contains(.basicDiagnostics),
               isDailyActivityTransaction(event) {
                return sanitizeActivity(event)
            }
            return nil
        }
    }

    nonisolated private static func isNativeCrash(_ event: Event) -> Bool {
        event.exceptions?.contains {
            $0.mechanism?.handled?.boolValue == false
        } == true
    }

    nonisolated static func sessionsEnabled(
        for capabilities: TelemetryCapabilities
    ) -> Bool {
        capabilities.contains(.crash)
    }

    nonisolated private static func sanitizeCrash(_ event: Event) -> Event {
        let environmentValues = event.context?[
            CrashEnvironmentContext.sentryContextKey
        ].map(CrashEnvironmentContext.sanitize)
        let operationValues = event.context?[
            CrashOperationContext.sentryContextKey
        ].map(CrashOperationContext.sanitize)

        event.message = nil
        event.error = nil
        event.logger = nil
        event.serverName = nil
        event.transaction = nil
        event.tags = nil
        event.extra = nil
        event.sdk = nil
        event.modules = nil
        event.fingerprint = nil
        event.user = sanitizedUser(event.user)
        event.breadcrumbs = []
        event.request = nil
        var contexts = [String: [String: Any]]()
        if let environmentValues, !environmentValues.isEmpty {
            contexts[CrashEnvironmentContext.sentryContextKey] = environmentValues
        }
        if let operationValues, !operationValues.isEmpty {
            contexts[CrashOperationContext.sentryContextKey] = operationValues
        }
        event.context = contexts.isEmpty ? nil : contexts

        event.exceptions?.forEach { exception in
            exception.value = nil
            exception.module = nil
            exception.mechanism?.desc = nil
            exception.mechanism?.data = nil
            exception.mechanism?.helpLink = nil
            sanitizeFrames(exception.stacktrace?.frames)
        }
        event.threads?.forEach { thread in
            thread.name = nil
            sanitizeFrames(thread.stacktrace?.frames)
        }
        if let stacktrace = event.stacktrace {
            sanitizeFrames(stacktrace.frames)
        }
        event.debugMeta?.forEach { image in
            if let codeFile = image.codeFile {
                image.codeFile = URL(fileURLWithPath: codeFile)
                    .lastPathComponent
            }
        }
        return event
    }

    nonisolated private static func isPerformanceTransaction(
        _ event: Event
    ) -> Bool {
        event.exceptions == nil
            && isAllowedPerformanceSerialization(event.serialize())
    }

    nonisolated static func isAllowedPerformanceSerialization(
        _ serialized: [String: Any]
    ) -> Bool {
        guard
            serialized["type"] as? String == "transaction",
            serialized["transaction"] as? String == "media_enhancement",
            let contexts = serialized["contexts"] as? [String: Any],
            let trace = contexts["trace"] as? [String: Any],
            trace["op"] as? String == "speechlens.enhancement",
            let spans = serialized["spans"] as? [Any],
            spans.isEmpty,
            serialized["exceptions"] == nil,
            var tags = serialized["tags"] as? [String: String],
            tags.removeValue(
                forKey: "_speechlens_transaction_contract"
            ) == "speechlens.enhancement/v1",
            let serializedMeasurements =
                serialized["measurements"] as? [String: Any],
            Set(serializedMeasurements.keys)
                == EnhancementPerformanceRecord.allowedMeasurementNames
        else { return false }

        var measurements = [String: Double]()
        measurements.reserveCapacity(serializedMeasurements.count)
        for (name, serializedValue) in serializedMeasurements {
            guard
                let valueDictionary = serializedValue as? [String: Any],
                Set(valueDictionary.keys) == ["value"],
                let number = valueDictionary["value"] as? NSNumber
            else { return false }
            let value = number.doubleValue
            guard value.isFinite && value >= 0 else { return false }
            measurements[name] = value
        }
        return EnhancementPerformancePayload(
            dimensions: tags,
            measurements: measurements
        ) != nil
    }

    nonisolated private static func sanitizePerformance(_ event: Event) -> Event {
        let trace = event.context?["trace"]
        event.message = nil
        event.error = nil
        event.logger = nil
        event.serverName = nil
        event.tags = (event.tags ?? [:]).filter {
            EnhancementPerformanceRecord.allowedDimensionNames.contains($0.key)
                && $0.value.utf8.count <= 128
                && !$0.value.contains("/")
                && !$0.value.contains("\\")
                && !$0.value.contains("\n")
                && !$0.value.contains("\r")
                && !$0.value.contains("://")
        }
        event.extra = nil
        event.sdk = nil
        event.modules = nil
        event.fingerprint = nil
        event.user = sanitizedUser(event.user)
        event.breadcrumbs = []
        event.request = nil
        event.context = trace.map { ["trace": $0] }
        event.exceptions = nil
        event.threads = nil
        event.stacktrace = nil
        event.debugMeta = nil
        return event
    }

    nonisolated private static func isDailyActivityTransaction(
        _ event: Event
    ) -> Bool {
        let serialized = event.serialize()
        guard
            serialized["type"] as? String == "transaction",
            serialized["transaction"] as? String == "app_daily_active",
            let contexts = serialized["contexts"] as? [String: Any],
            let trace = contexts["trace"] as? [String: Any],
            trace["op"] as? String == "speechlens.activity",
            let spans = serialized["spans"] as? [Any],
            spans.isEmpty,
            serialized["exceptions"] == nil,
            var tags = serialized["tags"] as? [String: String],
            tags.removeValue(forKey: "_speechlens_transaction_contract")
                == "speechlens.activity/v1",
            Set(tags.keys) == DailyActivityRecord.allowedDimensionNames
        else { return false }
        if let measurements = serialized["measurements"] as? [String: Any],
           !measurements.isEmpty {
            return false
        }
        return tags.values.allSatisfy(isSafeTagValue)
    }

    nonisolated private static func sanitizeActivity(_ event: Event) -> Event {
        sanitizeDiagnosticTransaction(
            event,
            allowedTags: DailyActivityRecord.allowedDimensionNames
        )
    }

    nonisolated private static func sanitizeDiagnosticTransaction(
        _ event: Event,
        allowedTags: Set<String>
    ) -> Event {
        let trace = event.context?["trace"]
        event.message = nil
        event.error = nil
        event.logger = nil
        event.serverName = nil
        event.tags = (event.tags ?? [:]).filter {
            allowedTags.contains($0.key) && isSafeTagValue($0.value)
        }
        event.extra = nil
        event.sdk = nil
        event.modules = nil
        event.fingerprint = nil
        event.user = sanitizedUser(event.user)
        event.breadcrumbs = []
        event.request = nil
        event.context = trace.map { ["trace": $0] }
        event.exceptions = nil
        event.threads = nil
        event.stacktrace = nil
        event.debugMeta = nil
        return event
    }

    nonisolated private static func sentryUser(_ userID: String) -> User {
        let user = User()
        user.userId = userID
        return user
    }

    nonisolated private static func sanitizedUser(_ user: User?) -> User? {
        guard let userID = user?.userId, UUID(uuidString: userID) != nil else {
            return nil
        }
        return sentryUser(userID)
    }

    nonisolated private static func isSafeTagValue(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= 128
            && !value.contains("/")
            && !value.contains("\\")
            && !value.contains("\n")
            && !value.contains("\r")
            && !value.contains("://")
    }

    nonisolated private static func sanitizeFrames(_ frames: [Frame]?) {
        frames?.forEach { frame in
            frame.fileName = nil
            frame.package = nil
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }
}

// SAFETY: All mutable capability state is accessed under `lock`.
private final class TelemetryConsentGate: @unchecked Sendable {
    private let lock = NSLock()
    private var value: TelemetryCapabilities = []

    var capabilities: TelemetryCapabilities {
        lock.withLock { value }
    }

    func setCapabilities(_ capabilities: TelemetryCapabilities) {
        lock.withLock { value = capabilities }
    }
}
