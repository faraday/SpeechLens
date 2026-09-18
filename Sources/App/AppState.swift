// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Combine
import Diagnostics
import Foundation
import Inference
import MediaIO
import OSLog
import Processing

enum AppEnhancementCompletionPolicy {
    static func isCurrent(
        activeOperationID: UUID?,
        completingOperationID: UUID
    ) -> Bool {
        activeOperationID == completingOperationID
    }
}

@MainActor
final class AppState: ObservableObject {
    private static let log = Logger(subsystem: "com.speechlens.app", category: "AppState")

    @Published private(set) var workflow: AppWorkflowState = .idle
    @Published private(set) var settings: InferenceSettings = .standard
    @Published private(set) var processingProfile: ProcessingProfile = .fast
    @Published private(set) var inferenceMode: InferenceMode = .standard
    @Published private(set) var pendingAction: AppPendingAction?

    let modelStore: ModelStore
    let playback: PlaybackController

    private let jobPreparer: any MediaJobPreparing
    private let fileChooser: any AppFileChoosing
    private let outputRevealer: any OutputRevealing
    private let enhancementService: any AudioEnhancementServicing
    private let outputURLPlanner: OutputURLPlanner
    private let processingSettingsStore: ProcessingSettingsStore
    private let diagnosticRecorder: AppDiagnosticRecorder
    private let performanceReporter: any AppEnhancementPerformanceReporting
    private let performanceEnvironment: DiagnosticEnvironment
    private let performanceBuildContext: EnhancementPerformanceBuildContext?

    private var processingTask: Task<Void, Never>?
    private var activeProcessingID: UUID?
    private var activeActionID: UUID?

    var canStartProcessing: Bool {
        processingTask == nil
            && pendingAction == nil
            && !workflow.locksInputAndSettings
            && modelStore.state.isReady
    }

    var canDownloadModel: Bool {
        processingTask == nil && pendingAction == nil && !workflow.locksInputAndSettings
    }

    var canChangeSettings: Bool { !workflow.locksInputAndSettings }

    init(
        modelStore: ModelStore = ModelStore(),
        playback: PlaybackController = PlaybackController(),
        jobPreparer: any MediaJobPreparing = NativeMediaJobPreparer(),
        fileChooser: any AppFileChoosing = AppKitFileChooser(),
        outputRevealer: any OutputRevealing = WorkspaceOutputRevealer(),
        enhancementService: any AudioEnhancementServicing = CachedAudioEnhancementService(),
        outputURLPlanner: OutputURLPlanner = OutputURLPlanner(),
        processingSettingsStore: ProcessingSettingsStore = ProcessingSettingsStore(),
        diagnosticRecorder: AppDiagnosticRecorder = AppDiagnosticRecorder(),
        performanceReporter: any AppEnhancementPerformanceReporting =
            NoOpEnhancementPerformanceReporter(),
        performanceEnvironment: DiagnosticEnvironment = .current(),
        performanceBuildContext: EnhancementPerformanceBuildContext? = .load()
    ) {
        self.modelStore = modelStore
        self.playback = playback
        self.jobPreparer = jobPreparer
        self.fileChooser = fileChooser
        self.outputRevealer = outputRevealer
        self.enhancementService = enhancementService
        self.outputURLPlanner = outputURLPlanner
        self.processingSettingsStore = processingSettingsStore
        self.diagnosticRecorder = diagnosticRecorder
        self.performanceReporter = performanceReporter
        self.performanceEnvironment = performanceEnvironment
        self.performanceBuildContext = performanceBuildContext

        let profile = processingSettingsStore.loadProfile()
        processingProfile = profile
        inferenceMode = processingSettingsStore.loadInferenceMode()
        settings = profile.presetSettings
            ?? processingSettingsStore.loadCustomSettings()
            ?? .standard
    }

    func selectProcessingProfile(_ profile: ProcessingProfile) {
        guard canChangeSettings else { return }
        processingProfile = profile
        settings = profile.presetSettings
            ?? processingSettingsStore.loadCustomSettings()
            ?? .standard
        processingSettingsStore.saveProfile(profile)
    }

    func updateChunkSeconds(_ value: Double) {
        guard canChangeSettings else { return }
        if let updated = try? settings.with(chunkSeconds: value) {
            applyCustomSettings(updated)
        }
    }

    func updateOverlapPortion(_ value: Double) {
        guard canChangeSettings else { return }
        if let updated = try? settings.with(overlapPortion: value) {
            applyCustomSettings(updated)
        }
    }

    func updateInferenceMode(_ mode: InferenceMode) {
        guard canChangeSettings else { return }
        inferenceMode = mode
        processingSettingsStore.saveInferenceMode(mode)
    }

    private func applyCustomSettings(_ updated: InferenceSettings) {
        settings = updated
        processingProfile = .custom
        processingSettingsStore.saveProfile(.custom)
        processingSettingsStore.saveCustomSettings(updated)
    }

    func pickAndProcess() {
        guard beginAction(.choosingMedia) else { return }
        let actionID = activeActionID
        Task { [weak self] in
            guard let self, let actionID else { return }
            let url = await self.fileChooser.chooseMedia()
            guard self.finishAction(actionID), let url else { return }
            self.process(inputURL: url)
        }
    }

    func process(inputURL: URL) {
        guard processingTask == nil,
              pendingAction == nil,
              !workflow.locksInputAndSettings else { return }
        let job = PendingMediaJob(inputURL: inputURL)
        diagnosticRecorder.begin(
            operation: .mediaEnhancement,
            modelVersion: modelStore.descriptor.version,
            modelSelection: diagnosticModelSelection,
            profile: processingProfile,
            settings: settings,
            phase: .preparing
        )
        transition(to: .preparing(job))

        guard modelStore.state.isReady else {
            transition(to: .failed(AppWorkflowFailure(
                category: .modelUnavailable,
                code: .modelUnavailable,
                technicalDetail: nil,
                job: job,
                info: nil
            )))
            return
        }

        let processingID = UUID()
        activeProcessingID = processingID
        let request = MediaProcessingRequest(
            job: job,
            settings: settings,
            options: MediaProcessingOptions(
                previewPolicy: .retainAudioAndWaveforms
            ),
            weightsURL: modelStore.weightsURL,
            mode: inferenceMode
        )
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.inspectAndRoute(request: request, operationID: processingID)
        }
    }

    func downloadModel() {
        guard canDownloadModel, !modelStore.state.isReady else { return }
        if case .downloading = modelStore.state { return }
        guard beginAction(.downloadingModel) else { return }
        diagnosticRecorder.begin(
            operation: .modelDownload,
            modelVersion: modelStore.descriptor.version,
            modelSelection: diagnosticModelSelection,
            phase: .modelPreparing
        )
        let actionID = activeActionID
        Task { [weak self] in
            guard let self, let actionID else { return }
            if await self.modelStore.downloadAndInstall(onProgress: { [weak self] progress in
                self?.diagnosticRecorder.recordModelPhase(progress.phase)
            }) {
                await self.enhancementService.invalidateModel()
            }
            self.diagnosticRecorder.finishModelOperation(state: self.modelStore.state)
            _ = self.finishAction(actionID)
        }
    }

    func cancelProcessing() {
        processingTask?.cancel()
    }

    /// Records an orderly application shutdown. Fatal signals and force quits
    /// cannot safely execute Swift cleanup; those are recovered as interrupted
    /// from the last persisted snapshot at the next launch.
    func prepareForApplicationTermination() {
        diagnosticRecorder.cancelCurrentOperation()
    }

    func selectAudioTrack(_ streamIndex: Int) {
        guard case .selectingAudioTrack(var context) = workflow,
              context.inspection.mediaInspection.audioTracks.contains(where: {
                  $0.streamIndex == streamIndex && $0.isSelectable
              }) else { return }
        context.selectedStreamIndex = streamIndex
        transition(to: .selectingAudioTrack(context))
    }

    func confirmAudioTrackSelection() {
        guard processingTask == nil,
              case .selectingAudioTrack(let context) = workflow,
              context.selectedTrack?.isSelectable == true else { return }
        transition(to: .preparing(context.request.job))
        let processingID = UUID()
        activeProcessingID = processingID
        processingTask = Task { [weak self] in
            guard let self else { return }
            await self.execute(
                request: context.request,
                inspection: context.inspection,
                selectedStreamIndex: context.selectedStreamIndex,
                operationID: processingID
            )
        }
    }

    func cancelAudioTrackSelection() {
        guard case .selectingAudioTrack = workflow else { return }
        playback.reset()
        diagnosticRecorder.cancelCurrentOperation()
        transition(to: .idle)
    }

    func revealOutput() {
        guard let outputURL = workflow.completedContext?.outputURL else { return }
        outputRevealer.reveal(outputURL)
    }

    private func inspectAndRoute(
        request: MediaProcessingRequest,
        operationID: UUID
    ) async {
        do {
            let inspection = try await jobPreparer.inspect(request.job.inputURL)
            guard activeProcessingID == operationID else { return }
            let media = inspection.mediaInspection
            diagnosticRecorder.recordInspection(
                media,
                selectedStreamIndex: media.suggestedAudioStreamIndex
            )
            if media.audioTracks.count > 1 {
                transition(to: .selectingAudioTrack(AudioTrackSelectionContext(
                    request: request,
                    inspection: inspection,
                    selectedStreamIndex: media.suggestedAudioStreamIndex
                )))
                finishProcessingOperation(operationID)
                return
            }
            await execute(
                request: request,
                inspection: inspection,
                selectedStreamIndex: media.suggestedAudioStreamIndex,
                operationID: operationID
            )
        } catch {
            publish(
                error: error,
                phase: .inspection,
                job: request.job,
                info: nil,
                operationID: operationID
            )
            finishProcessingOperation(operationID)
        }
    }

    private func execute(
        request: MediaProcessingRequest,
        inspection: InspectedMediaJob,
        selectedStreamIndex: Int,
        operationID: UUID
    ) async {
        var inspectedInfo: AudioFileInfo?
        var resolvedJob = request.job
        var failurePhase = AppWorkflowFailurePhase.preparation
        defer { finishProcessingOperation(operationID) }

        do {
            let startedAt = ContinuousClock.now
            let preparedJob = try await jobPreparer.prepare(
                inspection,
                selectedAudioStreamIndex: selectedStreamIndex,
                options: request.options,
                destinationPlanner: { [outputURLPlanner] plan in
                    outputURLPlanner.outputURL(
                        for: request.job.inputURL,
                        outputContainer: plan.outputContainer
                    )
                }
            )
            let info = AppInspectedMedia(preparedJob: preparedJob)
            diagnosticRecorder.recordPreparedJob(preparedJob)
            inspectedInfo = info.audioInfo
            resolvedJob = PendingMediaJob(
                inputURL: preparedJob.inputURL,
                outputURL: preparedJob.outputURL
            )
            let context = MediaJobContext(
                job: resolvedJob,
                preparedJob: preparedJob,
                info: info
            )
            failurePhase = .processing
            let result = try await enhancementService.enhance(
                request: AudioEnhancementRequest(
                    preparedJob: preparedJob,
                    weightsURL: request.weightsURL,
                    settings: request.settings,
                    mode: request.mode
                ),
                event: { [weak self] event in
                    Task { @MainActor in
                        guard let self, self.activeProcessingID == operationID else { return }
                        switch event {
                        case .loadingModel:
                            self.transition(to: .loadingModel(context))
                        case .progress(let progress):
                            self.transition(to: .processing(context, progress))
                        }
                    }
                }
            )
            let appOperationWall = startedAt.duration(to: .now)
            guard AppEnhancementCompletionPolicy.isCurrent(
                activeOperationID: activeProcessingID,
                completingOperationID: operationID
            ) else { return }
            let performanceRecord = performanceBuildContext.flatMap {
                EnhancementPerformanceRecord(
                    result: result,
                    profile: processingProfile,
                    settings: request.settings,
                    modelArtifactVersion: modelStore.descriptor.version,
                    modelSelection: diagnosticModelSelection,
                    diagnosticEnvironment: performanceEnvironment,
                    buildContext: $0
                )
            }
            diagnosticRecorder.recordResult(result)
            if let previewAssets = result.previewAssets {
                playback.prepareComparison(
                    previewAssets: previewAssets,
                    durationSeconds: result.outputInfo.selectedAudio.durationSeconds
                )
            } else {
                playback.prepareComparison(
                    inputURL: resolvedJob.inputURL,
                    outputURL: preparedJob.outputURL,
                    durationSeconds: result.outputInfo.selectedAudio.durationSeconds
                )
            }
            if let issue = playback.issue {
                diagnosticRecorder.recordPlaybackIssue(issue)
            }
            transition(to: .completed(MediaJobContext(
                job: resolvedJob,
                preparedJob: preparedJob,
                info: info,
                notices: result.notices,
                processingDurationSeconds: Self.seconds(appOperationWall)
            )))
            if let performanceRecord {
                performanceReporter.submit(performanceRecord)
            }
            if result.previewAssets == nil {
                Task { [weak playback] in
                    await playback?.loadWaveforms(
                        inputURL: resolvedJob.inputURL,
                        outputURL: preparedJob.outputURL,
                        inputAudioStreamIndex: result.inputInfo.selectedAudioStreamIndex,
                        outputAudioStreamIndex: result.outputInfo.selectedAudioStreamIndex
                    )
                }
            }
        } catch {
            publish(
                error: error,
                phase: failurePhase,
                job: resolvedJob,
                info: inspectedInfo,
                operationID: operationID
            )
        }
    }

    private func publish(
        error: Error,
        phase: AppWorkflowFailurePhase,
        job: PendingMediaJob,
        info: AudioFileInfo?,
        operationID: UUID
    ) {
        guard activeProcessingID == operationID else { return }
        if error is CancellationError {
            transition(to: .cancelled(job, info))
            return
        }
        let failure = AppWorkflowFailureMapper.failure(
            for: error,
            phase: phase,
            job: job,
            info: info
        )
        if failure.category == .metalCompatibility, let detail = failure.technicalDetail {
            Self.log.error("Metal inference compatibility failure: \(detail, privacy: .private)")
        }
        transition(to: .failed(failure))
    }

    private func finishProcessingOperation(_ operationID: UUID) {
        guard activeProcessingID == operationID else { return }
        activeProcessingID = nil
        processingTask = nil
    }

    private static func seconds(_ duration: Duration) -> Double {
        let components = duration.components
        return Double(components.seconds) + Double(components.attoseconds) / 1e18
    }

    func latestDiagnosticReport() -> DiagnosticReport? {
        diagnosticRecorder.latestReport()
    }

    func observeDiagnosticReports(
        _ observer: @escaping (DiagnosticReport?) -> Void
    ) {
        diagnosticRecorder.setReportObserver(observer)
    }

    func latestRenderedDiagnosticReport() -> String? {
        diagnosticRecorder.latestRenderedReport()
    }

    private var diagnosticModelSelection: DiagnosticModelSelection {
        switch modelStore.state {
        case .ready:
            return .default
        case .missing, .downloading, .failed:
            return .unavailable
        }
    }

    private func transition(to state: AppWorkflowState) {
        workflow = state
        diagnosticRecorder.record(state: state)
    }

    private func beginAction(_ action: AppPendingAction) -> Bool {
        guard processingTask == nil, pendingAction == nil, !workflow.locksInputAndSettings else {
            return false
        }
        let actionID = UUID()
        activeActionID = actionID
        pendingAction = action
        return true
    }

    private func isActiveAction(_ actionID: UUID) -> Bool {
        activeActionID == actionID
    }

    @discardableResult
    private func finishAction(_ actionID: UUID) -> Bool {
        guard isActiveAction(actionID) else { return false }
        activeActionID = nil
        pendingAction = nil
        return true
    }
}
