// SPDX-License-Identifier: Apache-2.0

import Foundation
import Diagnostics
import Inference
import MediaIO
import Processing
import XCTest
@testable import App

@MainActor
final class AppStateWorkflowOutcomeTests: XCTestCase {
    func testModelUnavailableProducesTypedFailureWithoutInspection() async throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppStateWorkflowTests")
        let defaults = try makeIsolatedDefaults(prefix: "AppStateWorkflowTests")
        let fixture = try WorkflowMediaFixture.make(root: root)
        let preparer = WorkflowJobPreparer(
            inspection: fixture.inspection,
            preparedJobs: fixture.preparedJobs
        )
        let service = WorkflowEnhancementService(outcome: .success(fixture.results[0]!))
        let app = AppState(
            modelStore: ModelStore(
                cacheDirectoryURL: root.appendingPathComponent("missing-cache")
            ),
            jobPreparer: preparer,
            enhancementService: service,
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(
                prefix: "AppStateWorkflowTests"
            )
        )

        app.process(inputURL: fixture.inputURL)

        guard case .failed(let failure) = app.workflow else {
            return XCTFail("Expected failure, got \(app.workflow)")
        }
        XCTAssertEqual(failure.category, .modelUnavailable)
        XCTAssertEqual(failure.job?.inputURL, fixture.inputURL)
        XCTAssertNil(failure.info)
        XCTAssertEqual(failure.code, .modelUnavailable)
        XCTAssertNil(failure.technicalDetail)
        XCTAssertEqual(
            englishText(
                AppFailurePresentation.message(for: failure)
            ),
            "Download the model before enhancing."
        )
        XCTAssertEqual(app.latestDiagnosticReport()?.outcome, .failed)
        XCTAssertEqual(
            app.latestDiagnosticReport()?.failure?.code,
            .modelUnavailable
        )
        let inspectionCount = await preparer.inspectionCount
        XCTAssertEqual(inspectionCount, 0)
    }

    func testSingleTrackSuccessTraversesPhasesAndPreservesRequestAndCompletionContext()
        async throws
    {
        let context = try makeWorkflowContext(gateInspection: true)
        context.app.selectProcessingProfile(.custom)
        context.app.updateChunkSeconds(17)

        context.app.process(inputURL: context.fixture.inputURL)
        guard case .preparing = context.app.workflow else {
            return XCTFail("Expected preparing")
        }

        await context.preparer.releaseInspection()
        await waitUntil { await context.service.requests.count == 1 }
        await waitForWorkflow(context.app) {
            if case .loadingModel = $0 { return true }
            return false
        }

        await context.service.releaseProgress()
        await waitForWorkflow(context.app) {
            guard case .processing(_, let progress) = $0 else { return false }
            return progress.fractionCompleted == 0.5
        }
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }

        let requests = await context.service.requests
        XCTAssertEqual(requests.count, 1)
        XCTAssertEqual(requests[0].settings.chunkSeconds, 17)
        XCTAssertEqual(requests[0].weightsURL, context.modelStore.weightsURL)
        XCTAssertEqual(requests[0].preparedJob.inputInfo.selectedAudioStreamIndex, 0)
        XCTAssertEqual(
            requests[0].preparedJob.options.previewPolicy,
            .retainAudioAndWaveforms
        )
        let selectedStreamIndices = await context.preparer.selectedStreamIndices
        let capturedOptions = await context.preparer.capturedOptions
        XCTAssertEqual(selectedStreamIndices, [0])
        XCTAssertEqual(capturedOptions.first?.previewPolicy, .retainAudioAndWaveforms)

        guard let completed = context.app.workflow.completedContext else {
            return XCTFail("Expected completed context")
        }
        XCTAssertEqual(completed.inputURL, context.fixture.inputURL)
        XCTAssertEqual(completed.outputURL, context.fixture.outputURL)
        XCTAssertEqual(
            completed.notices,
            [.auxiliaryStreamsOmitted(streamIndices: [7])]
        )
        XCTAssertNotNil(completed.processingDurationSeconds)
        XCTAssertEqual(completed.info.audioInfo.sampleRate, 48_000)
        XCTAssertTrue(context.app.canStartProcessing)
        XCTAssertTrue(context.app.canDownloadModel)
        XCTAssertTrue(context.app.canChangeSettings)
        XCTAssertEqual(context.app.playback.duration, 2)
        XCTAssertNil(context.app.playback.issue)
        let report = try XCTUnwrap(context.app.latestDiagnosticReport())
        XCTAssertEqual(report.outcome, .completed)
        XCTAssertEqual(report.inputMedia?.container, "wav")
        XCTAssertEqual(report.outputMedia?.sampleRate, 48_000)
        XCTAssertEqual(report.outputPlan?.selectedAudioStreamIndex, 0)
        XCTAssertEqual(
            report.notices.map(\.code),
            [.auxiliaryStreamsOmitted]
        )
    }

    func testMultiTrackSelectionValidatesChoicesResumesAndCanCancel() async throws {
        let context = try makeWorkflowContext(trackCount: 3, unavailableLastTrack: true)

        context.app.process(inputURL: context.fixture.inputURL)
        await waitForWorkflow(context.app) {
            if case .selectingAudioTrack = $0 { return true }
            return false
        }
        guard case .selectingAudioTrack(let initial) = context.app.workflow else {
            return XCTFail("Expected selection")
        }
        XCTAssertEqual(initial.selectedStreamIndex, 0)

        context.app.selectAudioTrack(999)
        context.app.selectAudioTrack(2)
        guard case .selectingAudioTrack(let unchanged) = context.app.workflow else {
            return XCTFail("Expected selection")
        }
        XCTAssertEqual(unchanged.selectedStreamIndex, 0)

        context.app.selectAudioTrack(1)
        guard case .selectingAudioTrack(let selected) = context.app.workflow else {
            return XCTFail("Expected selection")
        }
        XCTAssertEqual(selected.selectedStreamIndex, 1)

        context.app.cancelAudioTrackSelection()
        XCTAssertEqual(context.app.workflow, .idle)

        context.app.process(inputURL: context.fixture.inputURL)
        await waitForWorkflow(context.app) {
            if case .selectingAudioTrack = $0 { return true }
            return false
        }
        context.app.selectAudioTrack(1)
        context.app.confirmAudioTrackSelection()
        await waitUntil { await context.service.requests.count == 1 }
        let selectedStreamIndices = await context.preparer.selectedStreamIndices
        XCTAssertEqual(selectedStreamIndices, [1])
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }
    }

    func testInspectionAndPreparationFailuresKeepPhaseAndVisibleMessage() async throws {
        let inspection = try makeWorkflowContext(preparerFailure: .inspection)
        inspection.app.process(inputURL: inspection.fixture.inputURL)
        await waitForWorkflow(inspection.app) {
            if case .failed = $0 { return true }
            return false
        }
        assertFailure(
            inspection.app.workflow,
            category: .inspection,
            detail: "inspection detail",
            expectedMessage: "SpeechLens couldn’t inspect this media. Choose another file or try again.",
            hasInfo: false
        )

        let preparation = try makeWorkflowContext(preparerFailure: .preparation)
        preparation.app.process(inputURL: preparation.fixture.inputURL)
        await waitForWorkflow(preparation.app) {
            if case .failed = $0 { return true }
            return false
        }
        assertFailure(
            preparation.app.workflow,
            category: .preparation,
            detail: "preparation detail",
            expectedMessage: "SpeechLens couldn’t prepare an output for this media. Choose another file or try again.",
            hasInfo: false
        )
    }

    func testEnhancementFailuresAreTypedAndPreserveResolvedContext() async throws {
        try await assertEnhancementFailure(
            .pipelineInitializationFailure(.modelNotFound(
                AppPrivacyTestFixture.modelURL
            )),
            category: .modelLoad,
            code: .inferenceModelNotFound,
            detail: "Model weights not found at "
                + AppPrivacyTestFixture.modelURL.path,
            message: "The downloaded model is no longer available. Download it again and retry."
        )
        try await assertEnhancementFailure(
            .pipelineInitializationFailure(.unsupportedModelArchitecture(
                "private architecture detail"
            )),
            category: .modelLoad,
            code: .inferenceUnsupportedModelArchitecture,
            detail: "Unsupported model architecture: private architecture detail",
            message: "The downloaded model isn’t compatible with this version of SpeechLens. Update SpeechLens or download the model again."
        )
        try await assertEnhancementFailure(
            .pipelineInitializationFailure(.weightMappingFailed(
                "private mapping detail"
            )),
            category: .modelLoad,
            code: .inferenceWeightMappingFailed,
            detail: "Weight mapping failed: private mapping detail",
            message: "SpeechLens couldn’t read the downloaded model. Download it again and retry."
        )
        try await assertEnhancementFailure(
            .pipelineInitializationFailure(.inferenceFailed("bad weights")),
            category: .modelLoad,
            code: .modelLoadFailed,
            detail: "Inference failed: bad weights",
            message: "SpeechLens couldn’t load the model. Download it again and retry."
        )
        try await assertEnhancementFailure(
            .pipelineInitializationFailure(.metalInferenceIncompatible(
                "unsupported state size"
            )),
            category: .metalCompatibility,
            code: .metalCompatibility,
            detail: "Metal inference incompatible: unsupported state size",
            message: englishText(
                AppFailurePresentation.message(for: .metalCompatibility)
            )
        )
        try await assertEnhancementFailure(
            .unexpectedPipelineInitializationFailure(
                "private unexpected detail"
            ),
            category: .modelLoad,
            code: .modelLoadFailed,
            detail: "private unexpected detail",
            message: "SpeechLens couldn’t load the model. Download it again and retry."
        )
        try await assertEnhancementFailure(
            .processingFailure,
            category: .processing,
            code: .unknownProcessing,
            detail: "processing detail",
            message: "Speech enhancement didn’t finish. Try again."
        )
    }

    func testPlaybackAndRevealOccurOnlyAfterSuccessfulCompletion() async throws {
        let context = try makeWorkflowContext()
        context.app.revealOutput()
        XCTAssertTrue(context.revealer.revealedURLs.isEmpty)
        XCTAssertEqual(context.app.playback.duration, 0)

        context.app.process(inputURL: context.fixture.inputURL)
        await waitUntil { await context.service.requests.count == 1 }
        XCTAssertEqual(context.app.playback.duration, 0)
        context.app.revealOutput()
        XCTAssertTrue(context.revealer.revealedURLs.isEmpty)

        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }
        context.app.revealOutput()

        XCTAssertEqual(context.app.playback.duration, 2)
        XCTAssertEqual(context.revealer.revealedURLs, [context.fixture.outputURL])
    }

    private func assertEnhancementFailure(
        _ outcome: WorkflowEnhancementService.Outcome,
        category: DiagnosticFailureCategory,
        code: DiagnosticFailureCode,
        detail: String,
        message: String
    ) async throws {
        let context = try makeWorkflowContext(serviceOutcome: outcome)
        context.app.process(inputURL: context.fixture.inputURL)
        await waitUntil { await context.service.requests.count == 1 }
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .failed = $0 { return true }
            return false
        }
        assertFailure(
            context.app.workflow,
            category: category,
            code: code,
            detail: detail,
            expectedMessage: message,
            hasInfo: true
        )
        guard case .failed(let failure) = context.app.workflow else { return }
        XCTAssertEqual(failure.job?.outputURL, context.fixture.outputURL)
        XCTAssertEqual(
            context.app.latestDiagnosticReport()?.failure?.code,
            code
        )
        let rendered = try XCTUnwrap(context.app.latestRenderedDiagnosticReport())
        XCTAssertFalse(rendered.contains(detail))
        XCTAssertFalse(
            rendered.contains(AppPrivacyTestFixture.privatePathPrefix)
        )
    }

    private func assertFailure(
        _ state: AppWorkflowState,
        category: DiagnosticFailureCategory,
        code: DiagnosticFailureCode? = nil,
        detail: String,
        expectedMessage: String,
        hasInfo: Bool
    ) {
        guard case .failed(let failure) = state else {
            return XCTFail("Expected failure, got \(state)")
        }
        XCTAssertEqual(failure.category, category)
        if let code {
            XCTAssertEqual(failure.code, code)
        }
        XCTAssertEqual(failure.technicalDetail, detail)
        XCTAssertEqual(failure.info != nil, hasInfo)
        let visibleMessage = englishText(
            AppFailurePresentation.message(for: failure)
        )
        XCTAssertEqual(visibleMessage, expectedMessage)
        XCTAssertFalse(visibleMessage.contains(detail))
    }
}
