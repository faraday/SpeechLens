// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import MediaIO
import Processing

struct AudioEnhancementRequest: Sendable {
    let preparedJob: PreparedMediaJob
    let weightsURL: URL
    let settings: InferenceSettings
    let mode: InferenceMode

    var inputURL: URL { preparedJob.inputURL }
    var outputURL: URL { preparedJob.outputURL }

    init(
        preparedJob: PreparedMediaJob,
        weightsURL: URL,
        settings: InferenceSettings,
        mode: InferenceMode = .standard
    ) {
        self.preparedJob = preparedJob
        self.weightsURL = weightsURL
        self.settings = settings
        self.mode = mode
    }
}

enum AudioEnhancementServiceEvent: Sendable, Equatable {
    case loadingModel
    case progress(MediaProcessingProgress)
}

enum AudioEnhancementServiceError: Error, Sendable, Equatable {
    case pipelineInitializationFailed(InferenceError)
    case unexpectedPipelineInitializationFailure(String)
}

protocol AudioEnhancementServicing: Sendable {
    func enhance(
        request: AudioEnhancementRequest,
        event: @escaping @Sendable (AudioEnhancementServiceEvent) -> Void
    ) async throws -> MediaProcessingResult

    func invalidateModel() async
}

protocol AppMediaProcessing: Sendable {
    typealias ProgressHandler = @Sendable (MediaProcessingProgress) -> Void

    func process(
        job: PreparedMediaJob,
        settings: InferenceSettings,
        progress: @escaping ProgressHandler
    ) async throws -> MediaProcessingResult
}

extension MediaFileEnhancementPipeline: AppMediaProcessing {}

actor CachedAudioEnhancementService: AudioEnhancementServicing {
    typealias PipelineFactory = @Sendable (URL, InferenceMode) throws -> any AppMediaProcessing

    private let makePipeline: PipelineFactory
    private var loadedWeightsURL: URL?
    private var loadedMode: InferenceMode?
    private var pipeline: (any AppMediaProcessing)?

    init(makePipeline: @escaping PipelineFactory = { weightsURL, mode in
        let enhancer = try MambaEnhancer(modelWeightsURL: weightsURL, mode: mode)
        return MediaFileEnhancementPipeline(enhancer: enhancer)
    }) {
        self.makePipeline = makePipeline
    }

    init(makePipeline: @escaping @Sendable (URL) throws -> any AppMediaProcessing) {
        self.makePipeline = { weightsURL, _ in try makePipeline(weightsURL) }
    }

    func enhance(
        request: AudioEnhancementRequest,
        event: @escaping @Sendable (AudioEnhancementServiceEvent) -> Void
    ) async throws -> MediaProcessingResult {
        try Task.checkCancellation()
        let weightsURL = request.weightsURL.standardizedFileURL
        let processingPipeline: any AppMediaProcessing
        if let pipeline, loadedWeightsURL == weightsURL, loadedMode == request.mode {
            processingPipeline = pipeline
        } else {
            event(.loadingModel)
            pipeline = nil
            loadedWeightsURL = nil
            loadedMode = nil
            do {
                let initializedPipeline = try makePipeline(weightsURL, request.mode)
                pipeline = initializedPipeline
                loadedWeightsURL = weightsURL
                loadedMode = request.mode
                processingPipeline = initializedPipeline
            } catch let error as InferenceError {
                throw AudioEnhancementServiceError
                    .pipelineInitializationFailed(error)
            } catch {
                throw AudioEnhancementServiceError
                    .unexpectedPipelineInitializationFailure(
                        error.localizedDescription
                    )
            }
        }

        try Task.checkCancellation()
        return try await processingPipeline.process(
            job: request.preparedJob,
            settings: request.settings,
            progress: { event(.progress($0)) }
        )
    }

    func invalidateModel() {
        loadedWeightsURL = nil
        loadedMode = nil
        pipeline = nil
    }
}
