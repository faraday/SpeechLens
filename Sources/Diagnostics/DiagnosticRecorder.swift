// SPDX-License-Identifier: Apache-2.0

import Foundation
import MediaIO
import OSLog
import Processing

public final class DiagnosticSnapshotStore: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.speechlens.diagnostics", category: "Persistence")

    public let fileURL: URL
    private let fileManager: FileManager
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public init(fileURL: URL, fileManager: FileManager = .default) {
        self.fileURL = fileURL
        self.fileManager = fileManager
        encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
    }

    public func load() -> DiagnosticReport? {
        guard fileManager.fileExists(atPath: fileURL.path) else { return nil }
        do {
            let report = try decoder.decode(DiagnosticReport.self, from: Data(contentsOf: fileURL))
            guard report.schemaVersion == DiagnosticReport.currentSchemaVersion else {
                remove()
                return nil
            }
            return report
        } catch {
            Self.log.error("Discarding unreadable diagnostic snapshot: \(error.localizedDescription, privacy: .private)")
            remove()
            return nil
        }
    }

    public func save(_ report: DiagnosticReport) throws {
        try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(report).write(to: fileURL, options: .atomic)
    }

    public func remove() { try? fileManager.removeItem(at: fileURL) }
}

public enum DiagnosticRecoveryPolicy: Sendable {
    case startFresh
    case restoreLatest
}

public final class DiagnosticRecorder: @unchecked Sendable {
    private static let log = Logger(subsystem: "com.speechlens.diagnostics", category: "Recorder")

    private let lock = NSLock()
    private let store: DiagnosticSnapshotStore
    private let environment: DiagnosticEnvironment
    private let now: () -> Date
    private let makeID: () -> UUID
    private var report: DiagnosticReport?

    public init(
        store: DiagnosticSnapshotStore,
        environment: DiagnosticEnvironment = .current(),
        recoveryPolicy: DiagnosticRecoveryPolicy = .startFresh,
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        self.store = store
        self.environment = environment
        self.now = now
        self.makeID = makeID
        if case .restoreLatest = recoveryPolicy {
            report = store.load()
            if report?.outcome == .inProgress {
                report?.outcome = .interrupted
                report?.phase = .terminal
                report?.updatedAt = now()
                persistBestEffort()
            }
        }
    }

    public func begin(
        operation: DiagnosticOperation,
        modelVersion: String,
        modelSelection: DiagnosticModelSelection,
        settings: DiagnosticSettings? = nil,
        phase: DiagnosticPhase
    ) throws {
        try lock.withLock {
            let timestamp = now()
            report = DiagnosticReport(
                schemaVersion: DiagnosticReport.currentSchemaVersion,
                reportID: makeID(),
                startedAt: timestamp,
                updatedAt: timestamp,
                environment: environment,
                operation: operation,
                outcome: .inProgress,
                phase: phase,
                model: DiagnosticModel(artifactVersion: modelVersion, selection: modelSelection),
                settings: settings,
                inputMedia: nil,
                outputMedia: nil,
                outputPlan: nil,
                notices: [],
                failure: nil,
                processingDurationSeconds: nil
            )
            try store.save(report!)
        }
    }

    public func setPhase(_ phase: DiagnosticPhase) { update { $0.phase = phase } }
    public func recordInputMedia(_ info: MediaFileInfo) { update { $0.inputMedia = DiagnosticMediaFacts(info) } }

    public func recordPreparedJob(_ job: PreparedMediaJob) {
        update {
            $0.inputMedia = DiagnosticMediaFacts(job.inputInfo)
            $0.outputPlan = DiagnosticOutputPlan(job.outputPlan)
            Self.merge(job.outputPlan.notices.map(DiagnosticNotice.init), into: &$0.notices)
        }
    }

    public func recordProgress(_ progress: MediaProcessingProgress) { setPhase(DiagnosticPhase(progress.phase)) }

    public func recordResult(_ result: MediaProcessingResult) {
        update {
            $0.inputMedia = DiagnosticMediaFacts(result.inputInfo)
            $0.outputMedia = DiagnosticMediaFacts(result.outputInfo)
            $0.outputPlan = DiagnosticOutputPlan(result.outputPlan)
            Self.merge(result.notices.map(DiagnosticNotice.init), into: &$0.notices)
        }
    }

    public func recordNotice(_ notice: DiagnosticNotice) {
        update { Self.merge([notice], into: &$0.notices) }
    }

    public func finishCompleted(processingDuration: TimeInterval? = nil) {
        update {
            $0.processingDurationSeconds = processingDuration
            $0.outcome = .completed
            $0.phase = .terminal
        }
    }

    public func finishCancelled() { finish(.cancelled) }

    public func finishFailure(category: DiagnosticFailureCategory, code: DiagnosticFailureCode) {
        update {
            $0.failure = DiagnosticFailure(category: category, code: code)
            $0.outcome = .failed
            $0.phase = .terminal
        }
    }

    public func finishFailure(_ error: Error, category: DiagnosticFailureCategory) {
        finishFailure(category: category, code: .classify(error, category: category))
    }

    public func latestReport() -> DiagnosticReport? { lock.withLock { report } }

    private func finish(_ outcome: DiagnosticOutcome) {
        update { $0.outcome = outcome; $0.phase = .terminal }
    }

    private func update(_ body: (inout DiagnosticReport) -> Void) {
        lock.withLock {
            guard var updated = report, updated.outcome == .inProgress else { return }
            body(&updated)
            guard updated != report else { return }
            updated.updatedAt = now()
            report = updated
            persistBestEffort()
        }
    }

    private func persistBestEffort() {
        guard let report else { return }
        do { try store.save(report) }
        catch {
            Self.log.error("Unable to persist diagnostic snapshot: \(error.localizedDescription, privacy: .private)")
        }
    }

    private static func merge(_ additions: [DiagnosticNotice], into notices: inout [DiagnosticNotice]) {
        for notice in additions where !notices.contains(notice) { notices.append(notice) }
    }
}
