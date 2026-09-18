// SPDX-License-Identifier: Apache-2.0

import Foundation
import MediaIO
import Processing
import XCTest
@testable import App

@MainActor
final class AppStateWorkflowConcurrencyTests: XCTestCase {
    func testCancellationDuringInspectionAndEnhancementProducesContextualCancellation()
        async throws
    {
        let inspection = try makeWorkflowContext(gateInspection: true)
        inspection.app.process(inputURL: inspection.fixture.inputURL)
        await waitUntil { await inspection.preparer.inspectionCount == 1 }
        inspection.app.cancelProcessing()
        await inspection.preparer.releaseInspection()
        await waitForWorkflow(inspection.app) {
            if case .cancelled = $0 { return true }
            return false
        }
        guard case .cancelled(let pendingJob, let info) = inspection.app.workflow else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertEqual(pendingJob.inputURL, inspection.fixture.inputURL)
        XCTAssertNil(info)
        XCTAssertTrue(inspection.app.canStartProcessing)
        XCTAssertEqual(inspection.app.latestDiagnosticReport()?.outcome, .cancelled)

        let enhancement = try makeWorkflowContext()
        enhancement.app.process(inputURL: enhancement.fixture.inputURL)
        await waitUntil { await enhancement.service.requests.count == 1 }
        enhancement.app.cancelProcessing()
        await enhancement.service.releaseProgress()
        await enhancement.service.releaseCompletion()
        await waitForWorkflow(enhancement.app) {
            if case .cancelled = $0 { return true }
            return false
        }
        guard case .cancelled(let resolvedJob, let resolvedInfo) = enhancement.app.workflow else {
            return XCTFail("Expected cancellation")
        }
        XCTAssertEqual(resolvedJob.outputURL, enhancement.fixture.outputURL)
        XCTAssertEqual(resolvedInfo?.sampleRate, 48_000)
        XCTAssertTrue(enhancement.app.canStartProcessing)
        XCTAssertEqual(enhancement.app.latestDiagnosticReport()?.outcome, .cancelled)
    }

    func testLateProgressCannotOverwriteCompletion() async throws {
        let context = try makeWorkflowContext()
        context.app.process(inputURL: context.fixture.inputURL)
        await waitUntil { await context.service.requests.count == 1 }
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }

        await context.service.emitRetainedProgress()
        for _ in 0..<20 { await Task.yield() }

        guard case .completed = context.app.workflow else {
            return XCTFail("Late progress overwrote terminal state: \(context.app.workflow)")
        }
    }

    func testWorkflowLockRejectsDuplicatesAndSnapshotsSettingsAndWeights() async throws {
        let context = try makeWorkflowContext(gateInspection: true)
        context.app.selectProcessingProfile(.custom)
        context.app.updateChunkSeconds(12)
        context.app.updateInferenceMode(.strict)
        let snapshottedWeights = context.modelStore.weightsURL

        context.app.process(inputURL: context.fixture.inputURL)
        context.app.process(inputURL: context.fixture.inputURL)
        context.app.updateChunkSeconds(30)
        XCTAssertEqual(context.app.settings.chunkSeconds, 12)
        XCTAssertNil(context.app.pendingAction)
        await waitUntil { await context.preparer.inspectionCount == 1 }
        let inspectionCount = await context.preparer.inspectionCount
        XCTAssertEqual(inspectionCount, 1)

        await context.preparer.releaseInspection()
        await waitUntil { await context.service.requests.count == 1 }
        let request = await context.service.requests[0]
        XCTAssertEqual(request.settings.chunkSeconds, 12)
        XCTAssertEqual(request.weightsURL, snapshottedWeights)
        XCTAssertEqual(request.mode, .strict)
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }
    }

    func testDuplicateMediaChooserAndDirectProcessingAreIgnoredWhileChooserIsPending()
        async throws
    {
        let context = try makeWorkflowContext()
        context.chooser.mediaResult = context.fixture.inputURL
        context.chooser.mediaGate = OneShotGate()

        context.app.pickAndProcess()
        context.app.pickAndProcess()
        context.app.process(inputURL: context.fixture.inputURL)
        await waitUntil { context.chooser.mediaChoiceCount == 1 }

        XCTAssertEqual(context.app.pendingAction, .choosingMedia)
        XCTAssertEqual(context.app.workflow, .idle)
        let pendingInspectionCount = await context.preparer.inspectionCount
        XCTAssertEqual(pendingInspectionCount, 0)

        await context.chooser.mediaGate?.open()
        await waitUntil { await context.service.requests.count == 1 }
        XCTAssertNil(context.app.pendingAction)
        let completedInspectionCount = await context.preparer.inspectionCount
        XCTAssertEqual(completedInspectionCount, 1)
        await context.service.releaseProgress()
        await context.service.releaseCompletion()
        await waitForWorkflow(context.app) {
            if case .completed = $0 { return true }
            return false
        }
    }

    func testSuccessfulDownloadInvalidatesOnceAndFailedDownloadDoesNotInvalidate() async throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppStateWorkflowTests")
        let modelData = Data("downloaded model".utf8)
        let sha = ModelStore.sha256Hex(for: modelData)
        let descriptor = try TestModelArtifactFactory.descriptor(expectedSHA256: sha)
        let manifest = try TestModelArtifactFactory.manifestData(sha256: sha)

        let successDefaults = try makeIsolatedDefaults(prefix: "AppStateWorkflowTests")
        let successfulStore = ModelStore(
            descriptor: descriptor,
            cacheDirectoryURL: root.appendingPathComponent("success-cache"),
            downloader: WorkflowModelDownloader(
                outcome: .success(manifest: manifest, model: modelData)
            )
        )
        let successfulService = WorkflowEnhancementService(
            outcome: .processingFailure
        )
        let successfulApp = AppState(
            modelStore: successfulStore,
            enhancementService: successfulService,
            processingSettingsStore: ProcessingSettingsStore(defaults: successDefaults),
            diagnosticRecorder: try makeDiagnosticRecorder(
                prefix: "AppStateWorkflowTests"
            )
        )

        successfulApp.downloadModel()
        await waitUntil { successfulApp.pendingAction == nil }
        XCTAssertTrue(successfulStore.state.isReady)
        XCTAssertEqual(successfulApp.latestDiagnosticReport()?.outcome, .completed)
        let successInvalidations = await successfulService.invalidationCount
        XCTAssertEqual(successInvalidations, 1)

        let failureDefaults = try makeIsolatedDefaults(prefix: "AppStateWorkflowTests")
        let failedStore = ModelStore(
            descriptor: descriptor,
            cacheDirectoryURL: root.appendingPathComponent("failure-cache"),
            downloader: WorkflowModelDownloader(outcome: .failure)
        )
        let failedService = WorkflowEnhancementService(outcome: .processingFailure)
        let failedApp = AppState(
            modelStore: failedStore,
            enhancementService: failedService,
            processingSettingsStore: ProcessingSettingsStore(defaults: failureDefaults),
            diagnosticRecorder: try makeDiagnosticRecorder(
                prefix: "AppStateWorkflowTests"
            )
        )

        failedApp.downloadModel()
        await waitUntil { failedApp.pendingAction == nil }
        XCTAssertFalse(failedStore.state.isReady)
        XCTAssertEqual(failedApp.latestDiagnosticReport()?.outcome, .failed)
        let failureInvalidations = await failedService.invalidationCount
        XCTAssertEqual(failureInvalidations, 0)
    }
}
