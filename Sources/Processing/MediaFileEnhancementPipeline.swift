// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import Inference
import MediaIO

/// Bounded native-rate enhancement for every supported media container.
public actor MediaFileEnhancementPipeline {
    public typealias ProgressHandler = @Sendable (MediaProcessingProgress) -> Void

    private let enhancer: any StreamingSpeechEnhancer
    private let engine: UnifiedFFmpegMediaEngine
    private let clock: MediaProcessingClock
    private let channelClock: MediaProcessingClock

    public init(enhancer: any StreamingSpeechEnhancer) {
        self.init(
            enhancer: enhancer,
            engine: UnifiedFFmpegMediaEngine(),
            clock: .continuous
        )
    }

    package init(
        enhancer: any StreamingSpeechEnhancer,
        engine: UnifiedFFmpegMediaEngine,
        clock: MediaProcessingClock = .continuous,
        channelClock: MediaProcessingClock = .continuous
    ) {
        self.enhancer = enhancer
        self.engine = engine
        self.clock = clock
        self.channelClock = channelClock
    }

    public func process(
        job: PreparedMediaJob,
        settings: InferenceSettings,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws -> MediaProcessingResult {
        let pipelineStart = clock.now()
        try Task.checkCancellation()
        try job.validateSourceIdentity()
        try job.validateDestinationState()
        let inputURL = job.inputURL
        let outputURL = job.outputURL
        let inputInfo = job.inputInfo
        let outputPlan = job.outputPlan
        let mediaPlan = job.mediaPlan
        try engine.validateOutputURL(outputURL, for: outputPlan)
        let audio = inputInfo.selectedAudio
        guard audio.sampleRate > 0, audio.channelCount > 0 else {
            throw MediaProcessingError.invalidInputLayout("sample rate and channels must be positive")
        }
        guard (audio.validFrameCount ?? 0) > 0 || audio.durationSeconds > 0 else {
            throw MediaProcessingError.emptyInput
        }

        let totalFrames = audio.validFrameCount
            ?? Int64((audio.durationSeconds * Double(audio.sampleRate)).rounded())
        let totalWork = try Self.workCount(frames: totalFrames, channels: audio.channelCount)
        progress(.init(phase: .preflight, completedWork: 0, totalWork: totalWork))

        let sinkConfiguration = AudioSinkConfiguration(outputPlan: outputPlan)
        let previewCapture: MediaPreviewCapture?
        if MediaPreviewCapture.shouldCreate(policy: job.options.previewPolicy) {
            previewCapture = try MediaPreviewCapture(
                audio: audio,
                timelineFrames: totalFrames,
                outputContainer: .wav
            )
        } else {
            previewCapture = nil
        }

        let workspace = try MediaTransactionWorkspace(destinationURL: outputURL)
        let source = try await engine.makeAudioSource(request: UnifiedAudioSourceRequest(
            url: inputURL,
            info: inputInfo,
            context: mediaPlan.inspectionContext
        ))
        defer { source.close() }
        let sink = try engine.makeReplacementAudioSink(request: UnifiedAudioSinkRequest(
            outputURL: workspace.temporaryOutputURL,
            sourceURL: inputURL,
            source: audio,
            configuration: sinkConfiguration, plan: mediaPlan
        ))

        var enhancementFinished = false
        defer {
            if !enhancementFinished { sink.cancel() }
        }

        let passStart = clock.now()
        let enhancement = try await MediaEnhancementPass(enhancer: enhancer).run(
            source: source,
            sink: sink,
            audio: audio,
            validation: mediaPlan.decodedInputValidation,
            previewCapture: previewCapture,
            settings: settings,
            totalWork: totalWork,
            clock: clock,
            channelClock: channelClock,
            progress: progress
        )
        let validationStart = clock.now()
        enhancementFinished = true
        guard FileManager.default.fileExists(
            atPath: workspace.temporaryOutputURL.path
        ) else {
            throw MediaProcessingError.destinationUnavailable(
                "encoded replacement was not created at "
                    + workspace.temporaryOutputURL.path
            )
        }

        try job.validateSourceIdentity()
        progress(.init(phase: .validating, completedWork: totalWork, totalWork: totalWork))
        let validation: UnifiedOutputValidation
        do {
            validation = try await engine.validateOutput(
                request: UnifiedOutputValidationRequest(
                    outputURL: workspace.temporaryOutputURL,
                    input: inputInfo,
                    plan: mediaPlan,
                    enhancedFrames: enhancement.enhancedFrames
                )
            )
        } catch let error as MediaProcessingError {
            throw error
        } catch {
            throw MediaProcessingError.outputIdentityChanged(
                "output inspection failed: \(error.localizedDescription)"
            )
        }
        let outputInfo = validation.outputInfo
        let commitStart = clock.now()
        try Task.checkCancellation()
        try job.validateSourceIdentity()
        try job.validateDestinationState()
        progress(.init(phase: .committing, completedWork: totalWork, totalWork: totalWork))
        do {
            try workspace.commit(to: outputURL)
        } catch {
            throw MediaProcessingError.destinationUnavailable(error.localizedDescription)
        }
        let pipelineEnd = clock.now()
        let timings = MediaProcessingTimingBoundaries(
            pipelineStart: pipelineStart,
            passStart: passStart,
            finalizingStart: enhancement.finalizingStart,
            validationStart: validationStart,
            commitStart: commitStart,
            pipelineEnd: pipelineEnd
        ).timings
        return MediaProcessingResult(
            inputInfo: validation.resultInputInfo,
            outputInfo: outputInfo,
            outputPlan: outputPlan,
            notices: outputPlan.notices,
            outputURL: outputURL,
            previewAssets: enhancement.previewAssets,
            timings: MediaProcessingTimings(
                total: timings.total,
                preflight: timings.preflight,
                enhancing: timings.enhancing,
                finalizing: timings.finalizing,
                validating: timings.validating,
                committing: timings.committing,
                enhancementPass: timings.enhancementPass,
                channelEnhancementPasses:
                    enhancement.channelEnhancementPasses
            )
        )
    }

    static func decodedFrameCountsMatch(
        codecFormatID: AudioFormatID,
        enhancedFrames: Int64,
        decodedFrames: Int64
    ) -> Bool {
        // Compressed decoders may expose padding or rounding, but never admit a
        // difference of one complete codec frame.
        let tolerance: Int64 = switch codecFormatID {
        case kAudioFormatMPEG4AAC: 1_023
        case kAudioFormatMPEGLayer3: 1_151
        default: 0
        }
        return abs(enhancedFrames - decodedFrames) <= tolerance
    }

    private static func workCount(frames: Int64, channels: Int) throws -> Int64 {
        let (value, overflow) = frames.multipliedReportingOverflow(by: Int64(channels))
        guard frames > 0, !overflow else {
            throw MediaProcessingError.invalidInputLayout("work count overflow")
        }
        return value
    }

}
