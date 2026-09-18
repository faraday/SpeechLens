// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Diagnostics
import Foundation
import MediaIO
import Processing
import TestSupport
import XCTest
@testable import App

struct WorkflowMediaFixture {
    let inputURL: URL
    let outputURL: URL
    let inspection: InspectedMediaJob
    let preparedJobs: [Int: PreparedMediaJob]
    let results: [Int: MediaProcessingResult]

    static func make(
        root: URL,
        trackCount: Int = 1,
        unavailableLastTrack: Bool = false
    ) throws -> WorkflowMediaFixture {
        let inputURL = root.appendingPathComponent("input.wav")
        let outputURL = root.appendingPathComponent("input-enhanced.wav")
        try Data("input".utf8).write(to: inputURL)
        try Data("output".utf8).write(to: outputURL)

        let descriptor = AudioStreamDescriptor(
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
                bitsPerChannel: 24
            ),
            estimatedBitRate: 2_304_000
        )
        let streams = (0..<trackCount).map {
            MediaStream(
                streamIndex: $0,
                mediaType: "soun",
                codecName: "pcm_s24le",
                isEnabled: true,
                languageCode: $0 == 0 ? "en" : "tr",
                title: "Track \($0 + 1)",
                startSeconds: 0,
                durationSeconds: 2
            )
        }
        let tracks = (0..<trackCount).map { index in
            MediaAudioTrackOption(
                streamIndex: index,
                ordinal: index + 1,
                title: "Track \(index + 1)",
                languageCode: index == 0 ? "en" : "tr",
                isEnabled: true,
                isMainProgramContent: index == 0,
                availability: unavailableLastTrack && index == trackCount - 1
                    ? .unavailable(reason: "unsupported codec")
                    : .selectable(descriptor)
            )
        }
        let asset = try MediaAssetInspection(
            container: .wav,
            durationSeconds: 2,
            tracks: streams,
            audioTracks: tracks,
            metadataItemCount: 1
        )
        let identity = MediaSourceIdentity(
            device: 1,
            inode: 2,
            size: 5,
            modificationSeconds: 3,
            modificationNanoseconds: 4
        )
        let inspectionContext = FFmpegInspectionContext(container: .wav)
        let inspection = InspectedMediaJob(
            inputURL: inputURL,
            mediaInspection: asset,
            sourceIdentity: identity,
            mediaContext: inspectionContext
        )

        var preparedJobs: [Int: PreparedMediaJob] = [:]
        var results: [Int: MediaProcessingResult] = [:]
        for track in tracks where track.isSelectable {
            let mediaInfo = try asset.mediaInfo(selectingAudioStreamIndex: track.streamIndex)
            let outputPlan = MediaOutputPlan(
                inputContainer: .wav,
                outputContainer: .wav,
                audioEncoding: AudioEncodingPlan(
                    container: .wav,
                    codecFormatID: kAudioFormatLinearPCM,
                    sampleRate: descriptor.sampleRate,
                    channelCount: descriptor.channelCount,
                    channelLayout: descriptor.channelLayout
                ),
                selectedAudioStreamIndex: track.streamIndex,
                copiedStreamIndices: streams
                    .map(\.streamIndex)
                    .filter { $0 != track.streamIndex },
                notices: [.auxiliaryStreamsOmitted(streamIndices: [7])]
            )
            let routing = try FFmpegStreamRouting(
                tracks: streams,
                selectedInputStreamIndex: track.streamIndex
            )
            let execution = UnifiedFFmpegExecutionPlan(
                inputContainer: .wav,
                outputPlan: outputPlan,
                routing: routing,
                encoder: .pcmS24LE,
                plannedBitRate: nil
            )
            let plan = try UnifiedMediaPlan(
                output: outputPlan,
                execution: execution,
                input: mediaInfo,
                inspectionContext: inspectionContext
            )
            let options = MediaProcessingOptions(previewPolicy: .retainAudioAndWaveforms)
            preparedJobs[track.streamIndex] = PreparedMediaJob(
                inputURL: inputURL,
                outputURL: outputURL,
                inputInfo: mediaInfo,
                options: options,
                sourceIdentity: identity,
                destinationState: .absent,
                mediaPlan: plan
            )
            results[track.streamIndex] = MediaProcessingResult(
                inputInfo: mediaInfo,
                outputInfo: mediaInfo,
                outputPlan: outputPlan,
                notices: [.auxiliaryStreamsOmitted(streamIndices: [7])],
                outputURL: outputURL,
                timings: MediaProcessingTimings(
                    total: .seconds(10),
                    preflight: .seconds(1),
                    enhancing: .seconds(6),
                    finalizing: .seconds(1),
                    validating: .seconds(1),
                    committing: .seconds(1),
                    enhancementPass: .seconds(7),
                    channelEnhancementPasses: [.seconds(2), .seconds(3)]
                )
            )
        }
        return WorkflowMediaFixture(
            inputURL: inputURL,
            outputURL: outputURL,
            inspection: inspection,
            preparedJobs: preparedJobs,
            results: results
        )
    }
}

@MainActor
extension XCTestCase {
    func waitForWorkflow(
        _ app: AppState,
        attempts: Int = 2_000,
        where predicate: (AppWorkflowState) -> Bool
    ) async {
        for _ in 0..<attempts {
            if predicate(app.workflow) { return }
            await Task.yield()
        }
        XCTFail("Workflow did not reach expected state; current state: \(app.workflow)")
    }

    func waitUntil(
        attempts: Int = 2_000,
        _ predicate: @escaping @MainActor () async -> Bool
    ) async {
        for _ in 0..<attempts {
            if await predicate() { return }
            await Task.yield()
        }
        XCTFail("Condition was not reached")
    }

    func makeReadyModelStore(root: URL) throws -> ModelStore {
        let modelData = Data("weights".utf8)
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(
            at: cache,
            withIntermediateDirectories: true
        )
        let sha = ModelStore.sha256Hex(for: modelData)
        let descriptor = try TestModelArtifactFactory.descriptor(
            expectedSHA256: sha
        )
        try modelData.write(
            to: cache.appendingPathComponent("model_mlx.safetensors")
        )
        try TestModelArtifactFactory.manifestData(sha256: sha).write(
            to: cache.appendingPathComponent("conversion-manifest.json")
        )
        return ModelStore(
            descriptor: descriptor,
            cacheDirectoryURL: cache
        )
    }
}

@MainActor
struct WorkflowTestContext {
    let root: URL
    let fixture: WorkflowMediaFixture
    let modelStore: ModelStore
    let preparer: WorkflowJobPreparer
    let service: WorkflowEnhancementService
    let chooser: WorkflowFileChooser
    let revealer: WorkflowOutputRevealer
    let app: AppState
}

@MainActor
extension XCTestCase {
    func makeWorkflowContext(
        trackCount: Int = 1,
        unavailableLastTrack: Bool = false,
        preparerFailure: WorkflowJobPreparer.Failure = .none,
        serviceOutcome: WorkflowEnhancementService.Outcome? = nil,
        gateInspection: Bool = false,
        performanceReporter: any AppEnhancementPerformanceReporting =
            NoOpEnhancementPerformanceReporter(),
        performanceEnvironment: DiagnosticEnvironment = .current(),
        performanceBuildContext: EnhancementPerformanceBuildContext? = nil
    ) throws -> WorkflowTestContext {
        let root = try makeTemporaryTestDirectory(prefix: "AppStateWorkflowTests")
        let defaults = try makeIsolatedDefaults(prefix: "AppStateWorkflowTests")
        let fixture = try WorkflowMediaFixture.make(
            root: root,
            trackCount: trackCount,
            unavailableLastTrack: unavailableLastTrack
        )
        let modelStore = try makeReadyModelStore(root: root)
        let preparer = WorkflowJobPreparer(
            inspection: fixture.inspection,
            preparedJobs: fixture.preparedJobs,
            failure: preparerFailure,
            gateInspection: gateInspection
        )
        let service = WorkflowEnhancementService(
            outcome: serviceOutcome ?? .success(fixture.results[0]!)
        )
        let chooser = WorkflowFileChooser()
        let revealer = WorkflowOutputRevealer()
        let app = AppState(
            modelStore: modelStore,
            playback: PlaybackController(),
            jobPreparer: preparer,
            fileChooser: chooser,
            outputRevealer: revealer,
            enhancementService: service,
            processingSettingsStore: ProcessingSettingsStore(defaults: defaults),
            diagnosticRecorder: try makeDiagnosticRecorder(
                prefix: "AppStateWorkflowTests"
            ),
            performanceReporter: performanceReporter,
            performanceEnvironment: performanceEnvironment,
            performanceBuildContext: performanceBuildContext
        )
        return WorkflowTestContext(
            root: root,
            fixture: fixture,
            modelStore: modelStore,
            preparer: preparer,
            service: service,
            chooser: chooser,
            revealer: revealer,
            app: app
        )
    }
}
