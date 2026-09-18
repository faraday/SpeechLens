// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation
import Inference
import MediaIO
import Processing
import XCTest
@testable import App

enum WorkflowTestError: Error, LocalizedError, Sendable, Equatable {
    case inspection
    case preparation
    case processing

    var errorDescription: String? {
        switch self {
        case .inspection: "inspection detail"
        case .preparation: "preparation detail"
        case .processing: "processing detail"
        }
    }
}

final class WorkflowModelDownloader: ModelArtifactDownloading, Sendable {
    enum Outcome: Sendable {
        case success(manifest: Data, model: Data)
        case failure
    }

    private let outcome: Outcome

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func fetchData(from url: URL) async throws -> Data {
        guard case .success(let manifest, _) = outcome else {
            throw WorkflowTestError.processing
        }
        return manifest
    }

    func fetchFile(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        guard case .success(_, let model) = outcome else {
            throw WorkflowTestError.processing
        }
        progress(Int64(model.count), Int64(model.count))
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(
            "speechlens-workflow-download-\(UUID().uuidString)"
        )
        try model.write(to: output)
        return output
    }
}

actor OneShotGate {
    private var isOpen: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(open: Bool = false) {
        isOpen = open
    }

    func wait() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

actor WorkflowJobPreparer: MediaJobPreparing {
    enum Failure: Sendable, Equatable {
        case none
        case inspection
        case preparation
    }

    private let inspection: InspectedMediaJob
    private let preparedJobs: [Int: PreparedMediaJob]
    private let failure: Failure
    private let inspectionGate: OneShotGate
    private let preparationGate: OneShotGate

    private(set) var inspectionCount = 0
    private(set) var preparationCount = 0
    private(set) var selectedStreamIndices: [Int] = []
    private(set) var capturedOptions: [MediaProcessingOptions] = []

    init(
        inspection: InspectedMediaJob,
        preparedJobs: [Int: PreparedMediaJob],
        failure: Failure = .none,
        gateInspection: Bool = false,
        gatePreparation: Bool = false
    ) {
        self.inspection = inspection
        self.preparedJobs = preparedJobs
        self.failure = failure
        inspectionGate = OneShotGate(open: !gateInspection)
        preparationGate = OneShotGate(open: !gatePreparation)
    }

    func inspect(_ url: URL) async throws -> InspectedMediaJob {
        inspectionCount += 1
        await inspectionGate.wait()
        try Task.checkCancellation()
        if failure == .inspection { throw WorkflowTestError.inspection }
        return inspection
    }

    func prepare(
        _ inspection: InspectedMediaJob,
        selectedAudioStreamIndex: Int,
        options: MediaProcessingOptions,
        destinationPlanner: @escaping MediaJobPreparer.DestinationPlanner
    ) async throws -> PreparedMediaJob {
        preparationCount += 1
        selectedStreamIndices.append(selectedAudioStreamIndex)
        capturedOptions.append(options)
        await preparationGate.wait()
        try Task.checkCancellation()
        if failure == .preparation { throw WorkflowTestError.preparation }
        guard let prepared = preparedJobs[selectedAudioStreamIndex] else {
            throw WorkflowTestError.preparation
        }
        _ = try destinationPlanner(prepared.outputPlan)
        return prepared
    }

    func releaseInspection() async {
        await inspectionGate.open()
    }

    func releasePreparation() async {
        await preparationGate.open()
    }
}

actor WorkflowEnhancementService: AudioEnhancementServicing {
    enum Outcome: Sendable {
        case success(MediaProcessingResult)
        case pipelineInitializationFailure(InferenceError)
        case unexpectedPipelineInitializationFailure(String)
        case processingFailure
    }

    private let outcome: Outcome
    private let progressGate = OneShotGate()
    private let completionGate = OneShotGate()
    private var retainedEvent: (@Sendable (AudioEnhancementServiceEvent) -> Void)?

    private(set) var requests: [AudioEnhancementRequest] = []
    private(set) var invalidationCount = 0

    init(outcome: Outcome) {
        self.outcome = outcome
    }

    func enhance(
        request: AudioEnhancementRequest,
        event: @escaping @Sendable (AudioEnhancementServiceEvent) -> Void
    ) async throws -> MediaProcessingResult {
        requests.append(request)
        retainedEvent = event
        event(.loadingModel)
        await progressGate.wait()
        try Task.checkCancellation()
        event(.progress(MediaProcessingProgress(
            phase: .enhancing,
            completedWork: 1,
            totalWork: 2
        )))
        await completionGate.wait()
        try Task.checkCancellation()
        switch outcome {
        case .success(let result):
            return result
        case .pipelineInitializationFailure(let error):
            throw AudioEnhancementServiceError.pipelineInitializationFailed(error)
        case .unexpectedPipelineInitializationFailure(let detail):
            throw AudioEnhancementServiceError
                .unexpectedPipelineInitializationFailure(detail)
        case .processingFailure:
            throw WorkflowTestError.processing
        }
    }

    func invalidateModel() {
        invalidationCount += 1
    }

    func releaseProgress() async {
        await progressGate.open()
    }

    func releaseCompletion() async {
        await completionGate.open()
    }

    func emitRetainedProgress() {
        retainedEvent?(.progress(MediaProcessingProgress(
            phase: .committing,
            completedWork: 1,
            totalWork: 1
        )))
    }
}

@MainActor
final class WorkflowFileChooser: AppFileChoosing {
    var mediaResult: URL?
    var mediaGate: OneShotGate?
    private(set) var mediaChoiceCount = 0

    func chooseMedia() async -> URL? {
        mediaChoiceCount += 1
        await mediaGate?.wait()
        return mediaResult
    }
}

@MainActor
final class WorkflowOutputRevealer: OutputRevealing {
    private(set) var revealedURLs: [URL] = []

    func reveal(_ url: URL) {
        revealedURLs.append(url)
    }
}
