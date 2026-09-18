// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Diagnostics
import Foundation
import Inference
import MediaIO
import Processing
import XCTest

final class DiagnosticsTests: XCTestCase {
    func testSchemaV2ModelDownloadRoundTripAndRenderingIncludesHardware() throws {
        let fixture = try makeRecorder()
        try fixture.recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .unavailable,
            phase: .modelPreparing
        )
        fixture.recorder.setPhase(.modelDownloading)
        fixture.recorder.recordNotice(DiagnosticNotice(
            code: .playbackPreviewFileMissing,
            severity: .warning
        ))
        fixture.recorder.finishFailure(category: .modelSetup, code: .modelDownloadNetwork)

        let report = try XCTUnwrap(fixture.store.load())
        XCTAssertEqual(report.schemaVersion, 2)
        XCTAssertEqual(report.operation, .modelDownload)
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.environment.hardware?.gpuName, "Test GPU")
        XCTAssertNil(report.settings)

        let rendered = DiagnosticReportRenderer.render(report)
        XCTAssertTrue(rendered.contains("Schema: 2"))
        XCTAssertTrue(rendered.contains("GPU: Test GPU"))
        XCTAssertTrue(rendered.contains("Code: model.download_network"))
        XCTAssertTrue(rendered.contains("User audio included: no"))
    }

    func testVersionOneAndCorruptSnapshotsAreDiscarded() throws {
        let fixture = try makeRecorder()
        try fixture.recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "external",
            modelSelection: .explicitWeights,
            settings: DiagnosticSettings(profile: "cli", settings: .standard),
            phase: .preparing
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fixture.store.fileURL))
                as? [String: Any]
        )
        object["schemaVersion"] = 1
        try JSONSerialization.data(withJSONObject: object).write(to: fixture.store.fileURL)
        XCTAssertNil(fixture.store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))

        try Data("not-json".utf8).write(to: fixture.store.fileURL)
        XCTAssertNil(fixture.store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.store.fileURL.path))
    }

    func testRecoveryMarksOnlyInProgressReportInterrupted() throws {
        let fixture = try makeRecorder()
        try fixture.recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .unavailable,
            phase: .modelVerifying
        )
        let restored = DiagnosticRecorder(
            store: fixture.store,
            environment: testEnvironment,
            recoveryPolicy: .restoreLatest,
            now: { Date(timeIntervalSince1970: 200) }
        )
        XCTAssertEqual(restored.latestReport()?.outcome, .interrupted)
        XCTAssertEqual(restored.latestReport()?.phase, .terminal)
        XCTAssertEqual(restored.latestReport()?.updatedAt, Date(timeIntervalSince1970: 200))

        let restoredAgain = DiagnosticRecorder(
            store: fixture.store,
            environment: testEnvironment,
            recoveryPolicy: .restoreLatest,
            now: { Date(timeIntervalSince1970: 300) }
        )
        XCTAssertEqual(restoredAgain.latestReport()?.updatedAt, Date(timeIntervalSince1970: 200))
    }

    func testNoOpUpdatesDoNotTouchTimestampAndTerminalRejectsLateEvents() throws {
        let root = try temporaryDirectory()
        let store = DiagnosticSnapshotStore(fileURL: root.appendingPathComponent("report.json"))
        var now = Date(timeIntervalSince1970: 100)
        let recorder = DiagnosticRecorder(
            store: store,
            environment: testEnvironment,
            now: { now }
        )
        try recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "external",
            modelSelection: .explicitWeights,
            settings: DiagnosticSettings(profile: "cli", settings: .standard),
            phase: .preparing
        )
        now = Date(timeIntervalSince1970: 101)
        recorder.setPhase(.preparing)
        XCTAssertEqual(recorder.latestReport()?.updatedAt, Date(timeIntervalSince1970: 100))

        let notice = DiagnosticNotice(code: .playbackPreviewFileMissing, severity: .warning)
        recorder.recordNotice(notice)
        recorder.recordNotice(notice)
        XCTAssertEqual(recorder.latestReport()?.notices, [notice])
        recorder.finishCancelled()
        recorder.finishFailure(category: .processing, code: .unknownProcessing)
        recorder.setPhase(.processingEnhancing)
        XCTAssertEqual(recorder.latestReport()?.outcome, .cancelled)
        XCTAssertNil(recorder.latestReport()?.failure)
        XCTAssertEqual(recorder.latestReport()?.phase, .terminal)
    }

    func testUnavailablePersistenceRetainsInMemoryReport() throws {
        let root = try temporaryDirectory()
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocking".utf8).write(to: blocker)
        let recorder = DiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: blocker.appendingPathComponent("report.json")
            ),
            environment: testEnvironment
        )
        XCTAssertThrowsError(try recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .unavailable,
            phase: .modelPreparing
        ))
        XCTAssertEqual(recorder.latestReport()?.outcome, .inProgress)
        recorder.setPhase(.modelDownloading)
        XCTAssertEqual(recorder.latestReport()?.phase, .modelDownloading)
    }

    func testRecorderNeverPersistsRawErrorDetailsOrPaths() throws {
        let fixture = try makeRecorder()
        try fixture.recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "external",
            modelSelection: .explicitWeights,
            settings: DiagnosticSettings(profile: "cli", settings: .standard),
            phase: .preparing
        )
        fixture.recorder.finishFailure(
            InferenceError.modelNotFound(
                URL(fileURLWithPath: "/Users/person/private.safetensors")
            ),
            category: .modelLoad
        )
        let text = try String(contentsOf: fixture.store.fileURL, encoding: .utf8)
        XCTAssertTrue(text.contains("inference.model_not_found"))
        XCTAssertFalse(text.contains("/Users/person"))
        XCTAssertFalse(text.contains("private.safetensors"))
        XCTAssertFalse(DiagnosticReportRenderer.render(try XCTUnwrap(fixture.store.load()))
            .contains("private.safetensors"))
    }

    func testClassifierCoversEverySharedDomainErrorFamily() {
        let mediaCases: [(MediaIOError, DiagnosticFailureCode)] = [
            (.unsupportedContainer("x"), .mediaUnsupportedContainer),
            (.unreadable("x"), .mediaUnreadable),
            (.protectedContent, .mediaProtectedContent),
            (.missingAudioTrack, .mediaMissingAudioTrack),
            (.noSelectableAudioTrack, .mediaNoSelectableAudioTrack),
            (.invalidAudioStreamSelection(2), .mediaInvalidAudioStreamSelection),
            (.invalidAudioFormat("x"), .mediaInvalidAudioFormat),
            (.unsupportedChannelLayout(3), .mediaUnsupportedChannelLayout),
            (.outputContainerMismatch(expected: "wav", actual: "caf"), .mediaOutputContainerMismatch),
            (.readerFailed("x"), .mediaReaderFailed),
            (.writerFailed("x"), .mediaWriterFailed),
            (.ffmpegUnavailable("x"), .mediaFFmpegUnavailable),
            (.ffmpegFailed("x"), .mediaFFmpegFailed),
        ]
        for (error, expected) in mediaCases {
            XCTAssertEqual(.classify(error, category: .processing), expected)
        }

        let processingCases: [(MediaProcessingError, DiagnosticFailureCode)] = [
            (.emptyInput, .processingEmptyInput),
            (.invalidInputLayout("x"), .processingInvalidInputLayout),
            (.inconsistentSessionBlockSize, .processingInconsistentSessionBlockSize),
            (.inconsistentChannelOutput, .processingInconsistentChannelOutput),
            (.invalidOutputPlan("x"), .processingInvalidOutputPlan),
            (.outputIdentityChanged("x"), .processingOutputIdentityChanged),
            (.destinationUnavailable("x"), .processingDestinationUnavailable),
            (.sourceUnavailable("x"), .processingSourceUnavailable),
            (.sourceChanged, .processingSourceChanged),
        ]
        for (error, expected) in processingCases {
            XCTAssertEqual(.classify(error, category: .processing), expected)
        }

        let inferenceCases: [(InferenceError, DiagnosticFailureCode)] = [
            (.modelNotFound(URL(fileURLWithPath: "/model")), .inferenceModelNotFound),
            (.unsupportedModelArchitecture("x"), .inferenceUnsupportedModelArchitecture),
            (.metalInferenceIncompatible("x"), .inferenceMetalCompatibility),
            (.weightMappingFailed("x"), .inferenceWeightMappingFailed),
            (.inferenceFailed("x"), .inferenceFailed),
        ]
        for (error, expected) in inferenceCases {
            XCTAssertEqual(.classify(error, category: .modelLoad), expected)
        }

        let audioCases: [(AudioIOError, DiagnosticFailureCode)] = [
            (.invalidBuffer("x"), .audioInvalidBuffer),
            (.fileNotFound("x"), .audioFileNotFound),
            (.unsupportedFormat("x"), .audioUnsupportedFormat),
            (.readFailed("x"), .audioReadFailed),
            (.writeFailed("x"), .audioWriteFailed),
        ]
        for (error, expected) in audioCases {
            XCTAssertEqual(.classify(error, category: .processing), expected)
        }

        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .inspection),
            .unknownInspection
        )
        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .preparation),
            .unknownPreparation
        )
        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .modelSetup),
            .modelSetupFailed
        )
        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .modelUnavailable),
            .modelUnavailable
        )
        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .modelLoad),
            .modelLoadFailed
        )
        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .metalCompatibility),
            .metalCompatibility
        )
        XCTAssertEqual(
            DiagnosticFailureCode.classify(TestFailure(), category: .processing),
            .unknownProcessing
        )
    }

    func testCurrentHardwareFactsAreAvailableWithoutAppOwnership() {
        let facts = DiagnosticHardwareFacts.current()
        XCTAssertGreaterThan(facts.cpuPhysicalCores, 0)
        XCTAssertGreaterThan(facts.cpuLogicalCores, 0)
    }

    private func makeRecorder() throws -> (
        recorder: DiagnosticRecorder,
        store: DiagnosticSnapshotStore
    ) {
        let root = try temporaryDirectory()
        let store = DiagnosticSnapshotStore(fileURL: root.appendingPathComponent("diagnostic.json"))
        return (
            DiagnosticRecorder(
                store: store,
                environment: testEnvironment,
                now: { Date(timeIntervalSince1970: 100) },
                makeID: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
            ),
            store
        )
    }

    private func temporaryDirectory() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private var testEnvironment: DiagnosticEnvironment {
        DiagnosticEnvironment(
            appVersion: "1.2.3",
            appBuild: "45",
            macOSVersion: "14.6.1",
            hardwareModel: "Mac14,5",
            processorCount: 8,
            physicalMemoryGiB: 16,
            hardware: DiagnosticHardwareFacts(
                cpuPhysicalCores: 8,
                cpuLogicalCores: 8,
                cpuPerformanceCores: 4,
                cpuEfficiencyCores: 4,
                gpuName: "Test GPU",
                gpuCoreCount: 10,
                gpuHasUnifiedMemory: true,
                gpuMaxWorkingSetGiB: 12
            )
        )
    }
}

private struct TestFailure: Error {}
