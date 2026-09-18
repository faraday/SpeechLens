// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation
import Inference
import MediaIO
import Processing

@MainActor
final class AppDiagnosticRecorder {
    private let recorder: DiagnosticRecorder
    private var reportObserver: ((DiagnosticReport?) -> Void)?

    init(
        store: DiagnosticSnapshotStore = DiagnosticSnapshotStore(
            fileURL: AppDiagnosticRecorder.defaultFileURL()
        ),
        environment: DiagnosticEnvironment = .current(),
        now: @escaping () -> Date = Date.init,
        makeID: @escaping () -> UUID = UUID.init
    ) {
        recorder = DiagnosticRecorder(
            store: store,
            environment: environment,
            recoveryPolicy: .restoreLatest,
            now: now,
            makeID: makeID
        )
    }

    func begin(
        operation: DiagnosticOperation,
        modelVersion: String,
        modelSelection: DiagnosticModelSelection,
        profile: ProcessingProfile? = nil,
        settings: InferenceSettings? = nil,
        phase: DiagnosticPhase
    ) {
        defer { notifyReportObserver() }
        let diagnosticSettings = profile.flatMap { profile in
            settings.map { DiagnosticSettings(profile: profile.rawValue, settings: $0) }
        }
        try? recorder.begin(
            operation: operation,
            modelVersion: modelVersion,
            modelSelection: modelSelection,
            settings: diagnosticSettings,
            phase: phase
        )
    }

    func record(state: AppWorkflowState) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .mediaEnhancement else { return }
        switch state {
        case .idle:
            return
        case .preparing:
            recorder.setPhase(.preparing)
        case .selectingAudioTrack(let context):
            if let info = try? context.inspection.mediaInspection.mediaInfo(
                selectingAudioStreamIndex: context.selectedStreamIndex
            ) {
                recorder.recordInputMedia(info)
            }
            recorder.setPhase(.selectingAudioTrack)
        case .loadingModel(let context):
            record(context: context)
            recorder.setPhase(.loadingModel)
        case .processing(let context, let progress):
            record(context: context)
            recorder.recordProgress(progress)
        case .completed(let context):
            record(context: context)
            recorder.finishCompleted(processingDuration: context.processingDurationSeconds)
        case .cancelled:
            recorder.finishCancelled()
        case .failed(let failure):
            recorder.finishFailure(category: failure.category, code: failure.code)
        }
    }

    func recordInspection(_ inspection: MediaAssetInspection, selectedStreamIndex: Int) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .mediaEnhancement,
              let info = try? inspection.mediaInfo(selectingAudioStreamIndex: selectedStreamIndex)
        else { return }
        recorder.recordInputMedia(info)
    }

    func recordPreparedJob(_ job: PreparedMediaJob) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .mediaEnhancement else { return }
        recorder.recordPreparedJob(job)
    }

    func recordResult(_ result: MediaProcessingResult) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .mediaEnhancement else { return }
        recorder.recordResult(result)
    }

    func recordPlaybackIssue(_ issue: PlaybackIssue) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .mediaEnhancement else { return }
        switch issue {
        case .previewFileMissing:
            recorder.recordNotice(DiagnosticNotice(
                code: .playbackPreviewFileMissing,
                severity: .warning
            ))
        }
    }

    func recordModelPhase(_ phase: ModelDownloadPhase) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .modelDownload else { return }
        recorder.setPhase(Self.phase(for: phase))
    }

    func finishModelOperation(state: ModelSetupState) {
        defer { notifyReportObserver() }
        guard recorder.latestReport()?.operation == .modelDownload else { return }
        switch state {
        case .ready:
            recorder.finishCompleted()
        case .failed(let failure):
            recorder.finishFailure(category: .modelSetup, code: failure.code)
        case .missing:
            recorder.finishFailure(category: .modelSetup, code: .modelUnavailable)
        case .downloading:
            break
        }
    }

    func cancelCurrentOperation() {
        recorder.finishCancelled()
        notifyReportObserver()
    }

    func setReportObserver(_ observer: @escaping (DiagnosticReport?) -> Void) {
        reportObserver = observer
        observer(recorder.latestReport())
    }

    func latestReport() -> DiagnosticReport? { recorder.latestReport() }
    func latestRenderedReport() -> String? { recorder.latestReport().map(DiagnosticReportRenderer.render) }

    private func record(context: MediaJobContext) {
        recorder.recordPreparedJob(context.preparedJob)
        for notice in context.notices { recorder.recordNotice(DiagnosticNotice(notice)) }
    }

    private func notifyReportObserver() {
        reportObserver?(recorder.latestReport())
    }

    private static func phase(for phase: ModelDownloadPhase) -> DiagnosticPhase {
        switch phase {
        case .preparing: .modelPreparing
        case .downloading: .modelDownloading
        case .verifying: .modelVerifying
        }
    }

    private static func defaultFileURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.temporaryDirectory
        return base
            .appendingPathComponent("SpeechLens/Diagnostics", isDirectory: true)
            .appendingPathComponent("latest-operation.json")
    }
}
