// SPDX-License-Identifier: Apache-2.0

import AudioIO
import AudioToolbox
import Diagnostics
import Foundation
import Inference
import MediaIO
import Processing
import XCTest
@testable import App

@MainActor
final class AppDiagnosticsTests: XCTestCase {
    func testPreparedNoticesSurviveLaterWorkflowStateRecording() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let fixture = try WorkflowMediaFixture.make(root: root)
        let prepared = try XCTUnwrap(fixture.preparedJobs[0])
        let recorder = AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: root.appendingPathComponent("latest-operation.json")
            ),
            environment: testEnvironment
        )
        recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "model-1",
            modelSelection: .default,
            profile: .balanced,
            settings: .standard,
            phase: .preparing
        )
        recorder.recordPreparedJob(prepared)
        recorder.record(state: .loadingModel(MediaJobContext(
            job: PendingMediaJob(
                inputURL: fixture.inputURL,
                outputURL: fixture.outputURL
            ),
            preparedJob: prepared,
            info: AppInspectedMedia(preparedJob: prepared)
        )))

        XCTAssertEqual(
            recorder.latestReport()?.notices.map(\.code),
            [.auxiliaryStreamsOmitted]
        )
    }

    func testSamePhaseTrackSelectionPersistsChangedMediaFacts() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let fixture = try WorkflowMediaFixture.make(root: root, trackCount: 2)
        let fileURL = root.appendingPathComponent("latest-operation.json")
        let recorder = AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(fileURL: fileURL),
            environment: testEnvironment
        )
        recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "model-1",
            modelSelection: .default,
            profile: .balanced,
            settings: .standard,
            phase: .preparing
        )
        let request = MediaProcessingRequest(
            job: PendingMediaJob(inputURL: fixture.inputURL),
            settings: .standard,
            options: .standard,
            weightsURL: root.appendingPathComponent("model.safetensors")
        )
        recorder.record(state: .selectingAudioTrack(AudioTrackSelectionContext(
            request: request,
            inspection: fixture.inspection,
            selectedStreamIndex: 0
        )))
        recorder.record(state: .selectingAudioTrack(AudioTrackSelectionContext(
            request: request,
            inspection: fixture.inspection,
            selectedStreamIndex: 1
        )))

        let persisted = DiagnosticSnapshotStore(fileURL: fileURL).load()
        XCTAssertEqual(persisted?.inputMedia?.selectedAudioStreamIndex, 1)
    }

    func testWorkflowFailureMapperClassifiesEveryDomainErrorFamily() {
        let mediaCases: [(MediaIOError, DiagnosticFailureCode)] = [
            (.unsupportedContainer("x"), .mediaUnsupportedContainer),
            (.unreadable("x"), .mediaUnreadable),
            (.protectedContent, .mediaProtectedContent),
            (.missingAudioTrack, .mediaMissingAudioTrack),
            (.noSelectableAudioTrack, .mediaNoSelectableAudioTrack),
            (.invalidAudioStreamSelection(2), .mediaInvalidAudioStreamSelection),
            (.invalidAudioFormat("x"), .mediaInvalidAudioFormat),
            (.unsupportedChannelLayout(3), .mediaUnsupportedChannelLayout),
            (
                .outputContainerMismatch(expected: "wav", actual: "caf"),
                .mediaOutputContainerMismatch
            ),
            (.readerFailed("x"), .mediaReaderFailed),
            (.writerFailed("x"), .mediaWriterFailed),
            (.ffmpegUnavailable("x"), .mediaFFmpegUnavailable),
            (.ffmpegFailed("x"), .mediaFFmpegFailed),
        ]
        for (error, code) in mediaCases {
            XCTAssertEqual(mapped(error, phase: .processing).code, code)
        }

        let processingCases: [(MediaProcessingError, DiagnosticFailureCode)] = [
            (.emptyInput, .processingEmptyInput),
            (.invalidInputLayout("x"), .processingInvalidInputLayout),
            (
                .inconsistentSessionBlockSize,
                .processingInconsistentSessionBlockSize
            ),
            (.inconsistentChannelOutput, .processingInconsistentChannelOutput),
            (.invalidOutputPlan("x"), .processingInvalidOutputPlan),
            (.outputIdentityChanged("x"), .processingOutputIdentityChanged),
            (.destinationUnavailable("x"), .processingDestinationUnavailable),
            (.sourceUnavailable("x"), .processingSourceUnavailable),
            (.sourceChanged, .processingSourceChanged),
        ]
        for (error, code) in processingCases {
            XCTAssertEqual(mapped(error, phase: .processing).code, code)
        }

        let inferenceCases: [(InferenceError, DiagnosticFailureCode)] = [
            (
                .modelNotFound(URL(fileURLWithPath: "/private/model")),
                .inferenceModelNotFound
            ),
            (
                .unsupportedModelArchitecture("x"),
                .inferenceUnsupportedModelArchitecture
            ),
            (.metalInferenceIncompatible("x"), .inferenceMetalCompatibility),
            (.weightMappingFailed("x"), .inferenceWeightMappingFailed),
            (.inferenceFailed("x"), .inferenceFailed),
        ]
        for (error, code) in inferenceCases {
            XCTAssertEqual(mapped(error, phase: .processing).code, code)
        }

        let audioCases: [(AudioIOError, DiagnosticFailureCode)] = [
            (.invalidBuffer("x"), .audioInvalidBuffer),
            (.fileNotFound("x"), .audioFileNotFound),
            (.unsupportedFormat("x"), .audioUnsupportedFormat),
            (.readFailed("x"), .audioReadFailed),
            (.writeFailed("x"), .audioWriteFailed),
        ]
        for (error, code) in audioCases {
            XCTAssertEqual(mapped(error, phase: .processing).code, code)
        }

        XCTAssertEqual(
            mapped(TestFailure(), phase: .inspection).code,
            .unknownInspection
        )
        XCTAssertEqual(
            mapped(TestFailure(), phase: .preparation).code,
            .unknownPreparation
        )
        XCTAssertEqual(
            mapped(TestFailure(), phase: .processing).code,
            .unknownProcessing
        )
        XCTAssertEqual(
            mapped(
                AudioEnhancementServiceError.pipelineInitializationFailed(
                    .inferenceFailed("x")
                ),
                phase: .processing
            ).code,
            .modelLoadFailed
        )
        XCTAssertEqual(
            mapped(
                AudioEnhancementServiceError.pipelineInitializationFailed(
                    .metalInferenceIncompatible("x")
                ),
                phase: .processing
            ).code,
            .metalCompatibility
        )
        XCTAssertEqual(
            mapped(
                AudioEnhancementServiceError
                    .unexpectedPipelineInitializationFailure("x"),
                phase: .processing
            ).code,
            .modelLoadFailed
        )
    }

    func testModelLoadFailuresPreserveTypedCodeContextAndPrivateDetail() {
        let job = PendingMediaJob(
            inputURL: AppPrivacyTestFixture.inputURL,
            outputURL: AppPrivacyTestFixture.outputURL
        )
        let info = AudioFileInfo(
            sampleRate: 48_000,
            channelCount: 2,
            frameCount: 96_000
        )
        let cases: [
            (
                error: InferenceError,
                category: DiagnosticFailureCategory,
                code: DiagnosticFailureCode
            )
        ] = [
            (
                .modelNotFound(AppPrivacyTestFixture.modelURL),
                .modelLoad,
                .inferenceModelNotFound
            ),
            (
                .unsupportedModelArchitecture("private architecture detail"),
                .modelLoad,
                .inferenceUnsupportedModelArchitecture
            ),
            (
                .weightMappingFailed("private mapping detail"),
                .modelLoad,
                .inferenceWeightMappingFailed
            ),
            (
                .metalInferenceIncompatible("private Metal detail"),
                .metalCompatibility,
                .metalCompatibility
            ),
            (
                .inferenceFailed("private package detail"),
                .modelLoad,
                .modelLoadFailed
            ),
        ]

        for item in cases {
            let failure = AppWorkflowFailureMapper.failure(
                for: AudioEnhancementServiceError
                    .pipelineInitializationFailed(item.error),
                phase: .processing,
                job: job,
                info: info
            )
            XCTAssertEqual(failure.category, item.category)
            XCTAssertEqual(failure.code, item.code)
            XCTAssertEqual(
                failure.technicalDetail,
                item.error.localizedDescription
            )
            XCTAssertEqual(failure.job, job)
            XCTAssertEqual(failure.info, info)
            let visible = englishText(
                AppFailurePresentation.message(for: failure)
            )
            XCTAssertFalse(
                visible.contains(AppPrivacyTestFixture.privatePathPrefix)
            )
            XCTAssertFalse(visible.contains("private"))
        }

        let unexpected = AppWorkflowFailureMapper.failure(
            for: AudioEnhancementServiceError
                .unexpectedPipelineInitializationFailure(
                    "private unexpected detail"
                ),
            phase: .processing,
            job: job,
            info: info
        )
        XCTAssertEqual(unexpected.category, .modelLoad)
        XCTAssertEqual(unexpected.code, .modelLoadFailed)
        XCTAssertEqual(
            unexpected.technicalDetail,
            "private unexpected detail"
        )
        XCTAssertEqual(unexpected.job, job)
        XCTAssertEqual(unexpected.info, info)
    }

    func testTypedNoticesPreserveSeverityAndPresentation() {
        let omitted = MediaOutputNotice.auxiliaryStreamsOmitted(
            streamIndices: [2, 11]
        )
        let fallback = MediaOutputNotice.fallbackContainer(
            input: .mp4,
            output: .mov
        )

        XCTAssertEqual(omitted.severity, .warning)
        XCTAssertEqual(fallback.severity, .information)
        XCTAssertEqual(
            englishText(AppMediaNoticePresentation.message(for: omitted)),
            "Auxiliary timecode, data, attachment, or opaque streams were not carried to the output."
        )
        XCTAssertEqual(
            englishText(AppMediaNoticePresentation.message(for: fallback)),
            "The media was written as MOV because the original container could not carry the native-rate output."
        )
    }

    func testTypedModelAndPlaybackPresentationPreservesVisibleText() {
        XCTAssertEqual(
            englishText(ModelSetupPresentation.detail(for: .missing)),
            "Download the converted MLX weights to enhance audio locally."
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.stage(for: .preparing)),
            "Preparing speech enhancer..."
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.stage(for: .downloading)),
            "Downloading enhancer weights..."
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.stage(for: .verifying)),
            "Verifying download..."
        )
        XCTAssertEqual(
            englishText(ModelSetupPresentation.detail(for: .failed(ModelSetupFailure(
                code: .modelDownloadNetwork,
                technicalDetail: "Download failed: The Internet connection appears to be offline."
            )))),
            "SpeechLens couldn’t reach the model download server. Check your connection and try again."
        )
        XCTAssertEqual(
            englishText(PlaybackIssuePresentation.message(for: .previewFileMissing)),
            "Preview unavailable: an audio file is missing."
        )
    }

    func testReportPersistsSanitizedFactsAndExcludesHostileText() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let fileURL = root.appendingPathComponent("latest-operation.json")
        let store = DiagnosticSnapshotStore(fileURL: fileURL)
        var now = Date(timeIntervalSince1970: 100)
        let recorder = AppDiagnosticRecorder(
            store: store,
            environment: testEnvironment,
            now: { now },
            makeID: { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        )
        recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "model-1",
            modelSelection: .default,
            profile: .fast,
            settings: .standard,
            phase: .preparing
        )
        let initialUpdate = try XCTUnwrap(recorder.latestReport()).updatedAt
        now = Date(timeIntervalSince1970: 101)
        recorder.record(state: .preparing(PendingMediaJob(
            inputURL: AppPrivacyTestFixture.inputURL
        )))
        XCTAssertEqual(recorder.latestReport()?.updatedAt, initialUpdate)

        let info = hostileMediaInfo()
        recorder.recordInspection(
            try MediaAssetInspection(
                container: info.container,
                durationSeconds: info.durationSeconds,
                tracks: info.tracks,
                audioTracks: [
                    MediaAudioTrackOption(
                        streamIndex: info.selectedAudioStreamIndex,
                        ordinal: 1,
                        title: AppPrivacyTestFixture.sensitiveTitle,
                        languageCode: AppPrivacyTestFixture.sensitiveLanguage,
                        isEnabled: true,
                        availability: .selectable(info.selectedAudio)
                    )
                ],
                metadataItemCount: info.metadataItemCount
            ),
            selectedStreamIndex: info.selectedAudioStreamIndex
        )
        let hostile = "\(AppPrivacyTestFixture.inputURL.path) "
            + "https://\(AppPrivacyTestFixture.sensitiveHost)"
        recorder.record(state: .failed(AppWorkflowFailure(
            category: .processing,
            code: .mediaFFmpegFailed,
            technicalDetail: hostile,
            job: PendingMediaJob(
                inputURL: AppPrivacyTestFixture.inputURL,
                outputURL: AppPrivacyTestFixture.outputURL
            ),
            info: info.selectedAudio.audioFileInfo
        )))

        let report = try XCTUnwrap(recorder.latestReport())
        XCTAssertEqual(report.outcome, .failed)
        XCTAssertEqual(report.failure?.code, .mediaFFmpegFailed)
        XCTAssertEqual(report.inputMedia?.codecFourCC, "lpcm")
        let rendered = try XCTUnwrap(recorder.latestRenderedReport())
        XCTAssertEqual(rendered, DiagnosticReportRenderer.render(report))
        let persisted = try String(contentsOf: fileURL, encoding: .utf8)
        for forbidden in [
            AppPrivacyTestFixture.privatePathPrefix,
            AppPrivacyTestFixture.sensitiveTitle,
            AppPrivacyTestFixture.sensitiveLanguage,
            AppPrivacyTestFixture.sensitiveHost,
        ] {
            XCTAssertFalse(rendered.contains(forbidden), forbidden)
            XCTAssertFalse(persisted.contains(forbidden), forbidden)
        }
        XCTAssertTrue(rendered.contains("User audio included: no"))
        XCTAssertTrue(rendered.contains("Code: media.ffmpeg_failed"))
    }

    func testUnfinishedReportBecomesInterruptedAcrossRecorderInstances() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let store = DiagnosticSnapshotStore(
            fileURL: root.appendingPathComponent("latest-operation.json")
        )
        let first = AppDiagnosticRecorder(
            store: store,
            environment: testEnvironment,
            now: { Date(timeIntervalSince1970: 100) }
        )
        first.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .unavailable,
            phase: .modelPreparing
        )

        let restored = AppDiagnosticRecorder(
            store: store,
            environment: testEnvironment,
            now: { Date(timeIntervalSince1970: 200) }
        )

        XCTAssertEqual(restored.latestReport()?.outcome, .interrupted)
        XCTAssertEqual(restored.latestReport()?.phase, .terminal)
        XCTAssertEqual(
            DiagnosticSnapshotStore(fileURL: store.fileURL).load()?.outcome,
            .interrupted
        )
    }

    func testOrderlyApplicationTerminationCancelsCurrentReport() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let recorder = AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: root.appendingPathComponent("latest-operation.json")
            ),
            environment: testEnvironment
        )
        recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .unavailable,
            phase: .modelPreparing
        )
        let state = AppState(diagnosticRecorder: recorder)

        state.prepareForApplicationTermination()

        XCTAssertEqual(recorder.latestReport()?.outcome, .cancelled)
        XCTAssertEqual(recorder.latestReport()?.phase, .terminal)
    }

    func testTerminalReportRejectsLateEventsAndRecordsPlaybackIssue() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let recorder = AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: root.appendingPathComponent("latest-operation.json")
            ),
            environment: testEnvironment
        )
        recorder.begin(
            operation: .mediaEnhancement,
            modelVersion: "model-1",
            modelSelection: .default,
            profile: .balanced,
            settings: .standard,
            phase: .preparing
        )
        recorder.recordPlaybackIssue(.previewFileMissing)
        recorder.cancelCurrentOperation()
        recorder.finishModelOperation(
            state: .failed(ModelSetupFailure(
                code: .modelDownloadNetwork,
                technicalDetail: "late private failure"
            ))
        )
        recorder.record(state: .failed(AppWorkflowFailure(
            category: .processing,
            code: .unknownProcessing,
            technicalDetail: "late private failure",
            job: nil,
            info: nil
        )))

        let report = try XCTUnwrap(recorder.latestReport())
        XCTAssertEqual(report.outcome, .cancelled)
        XCTAssertNil(report.failure)
        XCTAssertEqual(
            report.notices.map(\.code),
            [.playbackPreviewFileMissing]
        )
    }

    func testCorruptAndUnsupportedSnapshotsAreDiscarded() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let fileURL = root.appendingPathComponent("latest-operation.json")
        let store = DiagnosticSnapshotStore(fileURL: fileURL)
        try Data("not-json".utf8).write(to: fileURL)
        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))

        let recorder = AppDiagnosticRecorder(
            store: store,
            environment: testEnvironment
        )
        recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .default,
            phase: .modelPreparing
        )
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(contentsOf: fileURL))
                as? [String: Any]
        )
        object["schemaVersion"] = 999
        try JSONSerialization.data(withJSONObject: object).write(to: fileURL)

        XCTAssertNil(store.load())
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    func testUnavailablePersistenceDoesNotAffectInMemoryReport() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppDiagnosticsTests")
        let blockingFile = root.appendingPathComponent("not-a-directory")
        try Data("blocking".utf8).write(to: blockingFile)
        let recorder = AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: blockingFile.appendingPathComponent("latest-operation.json")
            ),
            environment: testEnvironment
        )

        recorder.begin(
            operation: .modelDownload,
            modelVersion: "model-1",
            modelSelection: .unavailable,
            phase: .modelPreparing
        )

        XCTAssertEqual(recorder.latestReport()?.outcome, .inProgress)
        XCTAssertNotNil(recorder.latestRenderedReport())
    }

    private func mapped(
        _ error: Error,
        phase: AppWorkflowFailurePhase
    ) -> AppWorkflowFailure {
        AppWorkflowFailureMapper.failure(
            for: error,
            phase: phase,
            job: nil,
            info: nil
        )
    }

    private var testEnvironment: DiagnosticEnvironment {
        DiagnosticEnvironment(
            appVersion: "1.2.3",
            appBuild: "45",
            macOSVersion: "14.6.1",
            hardwareModel: "Mac14,5",
            processorCount: 8,
            physicalMemoryGiB: 16
        )
    }

    private func hostileMediaInfo() -> MediaFileInfo {
        let audio = AudioStreamDescriptor(
            sampleRate: 48_000,
            channelCount: 2,
            validFrameCount: 96_000,
            presentationStartSeconds: 0,
            durationSeconds: 2,
            channelLayout: AudioChannelLayoutDescriptor(
                rawData: nil,
                inferred: true,
                ffmpegName: "stereo"
            ),
            codec: AudioCodecDescriptor(
                formatID: kAudioFormatLinearPCM,
                fourCC: "lpcm",
                bitsPerChannel: 32
            ),
            estimatedBitRate: nil
        )
        return MediaFileInfo(
            container: .mov,
            durationSeconds: 2,
            tracks: [
                MediaStream(
                    streamIndex: 3,
                    mediaType: "soun",
                    codecName: "pcm_f32le",
                    isEnabled: true,
                    languageCode: AppPrivacyTestFixture.sensitiveLanguage,
                    title: AppPrivacyTestFixture.sensitiveTitle,
                    startSeconds: 0,
                    durationSeconds: 2
                )
            ],
            selectedAudioStreamIndex: 3,
            selectedAudio: audio,
            metadataItemCount: 9
        )
    }
}

private struct TestFailure: Error {}
