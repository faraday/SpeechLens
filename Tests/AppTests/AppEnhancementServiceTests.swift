// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import Processing
import XCTest
@testable import App

@MainActor
final class AppEnhancementServiceTests: XCTestCase {
    func testKnownInferenceFailuresSurvivePipelineCreation() async throws {
        let (request, _) = try makeRequestFixture()
        let failures: [InferenceError] = [
            .modelNotFound(AppPrivacyTestFixture.modelURL),
            .unsupportedModelArchitecture("hostile architecture detail"),
            .metalInferenceIncompatible("hostile Metal detail"),
            .weightMappingFailed("hostile mapping detail"),
            .inferenceFailed("hostile inference detail"),
        ]

        for expected in failures {
            let service = CachedAudioEnhancementService { _ in
                throw expected
            }
            do {
                _ = try await service.enhance(request: request) { _ in }
                XCTFail("Expected \(expected)")
            } catch let error as AudioEnhancementServiceError {
                XCTAssertEqual(error, .pipelineInitializationFailed(expected))
            } catch {
                XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testUnknownPipelineCreationFailureUsesGenericBoundary() async throws {
        let (request, _) = try makeRequestFixture()
        let service = CachedAudioEnhancementService { _ in
            throw WorkflowTestError.processing
        }

        do {
            _ = try await service.enhance(request: request) { _ in }
            XCTFail("Expected model-load failure")
        } catch let error as AudioEnhancementServiceError {
            XCTAssertEqual(
                error,
                .unexpectedPipelineInitializationFailure("processing detail")
            )
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    func testCachedAndNewPipelinesUseSelectedNonoptionalPipeline() async throws {
        let (request, result) = try makeRequestFixture()
        let cachedProcessor = SuccessfulAppMediaProcessor(result: result)
        let reinitializedProcessor = SuccessfulAppMediaProcessor(result: result)
        let factory = AppMediaPipelineFactorySpy(pipelines: [
            cachedProcessor,
            reinitializedProcessor,
        ])
        let service = CachedAudioEnhancementService {
            factory.makePipeline(weightsURL: $0)
        }

        _ = try await service.enhance(request: request) { _ in }
        _ = try await service.enhance(request: request) { _ in }

        XCTAssertEqual(factory.requestedWeightsURLs, [
            request.weightsURL.standardizedFileURL,
        ])
        let cachedProcessingCount = await cachedProcessor.processingCount
        XCTAssertEqual(cachedProcessingCount, 2)
        let unusedProcessingCount = await reinitializedProcessor.processingCount
        XCTAssertEqual(unusedProcessingCount, 0)

        let alternateRequest = AudioEnhancementRequest(
            preparedJob: request.preparedJob,
            weightsURL: request.weightsURL
                .deletingLastPathComponent()
                .appendingPathComponent("alternate-model.safetensors"),
            settings: request.settings
        )
        _ = try await service.enhance(request: alternateRequest) { _ in }

        XCTAssertEqual(factory.requestedWeightsURLs, [
            request.weightsURL.standardizedFileURL,
            alternateRequest.weightsURL.standardizedFileURL,
        ])
        let originalProcessingCount = await cachedProcessor.processingCount
        XCTAssertEqual(originalProcessingCount, 2)
        let reinitializedProcessingCount =
            await reinitializedProcessor.processingCount
        XCTAssertEqual(reinitializedProcessingCount, 1)
    }

    func testChangingInferenceModeRebuildsCachedPipeline() async throws {
        let (request, result) = try makeRequestFixture()
        let standardProcessor = SuccessfulAppMediaProcessor(result: result)
        let strictProcessor = SuccessfulAppMediaProcessor(result: result)
        let factory = ModeCapturingPipelineFactorySpy(pipelines: [
            standardProcessor,
            strictProcessor,
        ])
        let service = CachedAudioEnhancementService { weightsURL, mode in
            factory.makePipeline(weightsURL: weightsURL, mode: mode)
        }

        _ = try await service.enhance(request: request) { _ in }
        _ = try await service.enhance(request: request) { _ in }
        _ = try await service.enhance(
            request: AudioEnhancementRequest(
                preparedJob: request.preparedJob,
                weightsURL: request.weightsURL,
                settings: request.settings,
                mode: .strict
            )
        ) { _ in }

        XCTAssertEqual(factory.requestedModes, [.standard, .strict])
        let standardCount = await standardProcessor.processingCount
        let strictCount = await strictProcessor.processingCount
        XCTAssertEqual(standardCount, 2)
        XCTAssertEqual(strictCount, 1)
    }

    private func makeRequestFixture()
        throws -> (AudioEnhancementRequest, MediaProcessingResult)
    {
        let root = try makeTemporaryTestDirectory(
            prefix: "AppEnhancementServiceTests"
        )
        let fixture = try WorkflowMediaFixture.make(root: root)
        return (
            AudioEnhancementRequest(
                preparedJob: try XCTUnwrap(fixture.preparedJobs[0]),
                weightsURL: root.appendingPathComponent("model.safetensors"),
                settings: .standard
            ),
            try XCTUnwrap(fixture.results[0])
        )
    }
}

private actor SuccessfulAppMediaProcessor: AppMediaProcessing {
    private let result: MediaProcessingResult
    private(set) var processingCount = 0

    init(result: MediaProcessingResult) {
        self.result = result
    }

    func process(
        job: PreparedMediaJob,
        settings: InferenceSettings,
        progress: @escaping ProgressHandler
    ) async throws -> MediaProcessingResult {
        processingCount += 1
        return result
    }
}

private final class AppMediaPipelineFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let pipelines: [any AppMediaProcessing]
    private var capturedWeightsURLs: [URL] = []

    init(pipelines: [any AppMediaProcessing]) {
        precondition(!pipelines.isEmpty)
        self.pipelines = pipelines
    }

    var requestedWeightsURLs: [URL] {
        lock.withLock { capturedWeightsURLs }
    }

    func makePipeline(weightsURL: URL) -> any AppMediaProcessing {
        lock.withLock {
            capturedWeightsURLs.append(weightsURL)
            let pipelineIndex = min(
                capturedWeightsURLs.count - 1,
                pipelines.count - 1
            )
            return pipelines[pipelineIndex]
        }
    }
}

private final class ModeCapturingPipelineFactorySpy: @unchecked Sendable {
    private let lock = NSLock()
    private let pipelines: [any AppMediaProcessing]
    private var capturedModes: [InferenceMode] = []

    init(pipelines: [any AppMediaProcessing]) {
        precondition(!pipelines.isEmpty)
        self.pipelines = pipelines
    }

    var requestedModes: [InferenceMode] {
        lock.withLock { capturedModes }
    }

    func makePipeline(weightsURL: URL, mode: InferenceMode) -> any AppMediaProcessing {
        lock.withLock {
            _ = weightsURL
            capturedModes.append(mode)
            return pipelines[min(capturedModes.count - 1, pipelines.count - 1)]
        }
    }
}
