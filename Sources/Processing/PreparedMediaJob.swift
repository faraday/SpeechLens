// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation
import MediaIO

public struct MediaSourceIdentity: Sendable, Equatable {
    public let device: UInt64
    public let inode: UInt64
    public let size: Int64
    public let modificationSeconds: Int64
    public let modificationNanoseconds: Int64

    package init(
        device: UInt64,
        inode: UInt64,
        size: Int64,
        modificationSeconds: Int64,
        modificationNanoseconds: Int64
    ) {
        self.device = device
        self.inode = inode
        self.size = size
        self.modificationSeconds = modificationSeconds
        self.modificationNanoseconds = modificationNanoseconds
    }

    static func capture(_ url: URL) throws -> MediaSourceIdentity {
        let descriptor = open(url.path, O_RDONLY | O_CLOEXEC)
        guard descriptor >= 0 else {
            throw MediaProcessingError.sourceUnavailable(url.path)
        }
        defer { close(descriptor) }
        var value = stat()
        guard fstat(descriptor, &value) == 0 else {
            throw MediaProcessingError.sourceUnavailable(url.path)
        }
        return MediaSourceIdentity(
            device: UInt64(value.st_dev),
            inode: UInt64(value.st_ino),
            size: Int64(value.st_size),
            modificationSeconds: Int64(value.st_mtimespec.tv_sec),
            modificationNanoseconds: Int64(value.st_mtimespec.tv_nsec)
        )
    }
}

public struct PreparedMediaJob: Sendable, Equatable {
    public let inputURL: URL
    public let outputURL: URL
    public let inputInfo: MediaFileInfo
    public let options: MediaProcessingOptions
    public let sourceIdentity: MediaSourceIdentity
    package let destinationState: MediaDestinationState
    package let mediaPlan: UnifiedMediaPlan

    public var outputPlan: MediaOutputPlan { mediaPlan.output }

    package init(
        inputURL: URL,
        outputURL: URL,
        inputInfo: MediaFileInfo,
        options: MediaProcessingOptions,
        sourceIdentity: MediaSourceIdentity,
        destinationState: MediaDestinationState,
        mediaPlan: UnifiedMediaPlan
    ) {
        self.inputURL = inputURL
        self.outputURL = outputURL
        self.inputInfo = inputInfo
        self.options = options
        self.sourceIdentity = sourceIdentity
        self.destinationState = destinationState
        self.mediaPlan = mediaPlan
    }

    func validateSourceIdentity() throws {
        guard try MediaSourceIdentity.capture(inputURL) == sourceIdentity else {
            throw MediaProcessingError.sourceChanged
        }
    }

    func validateDestinationState() throws {
        guard try MediaDestinationState.capture(outputURL) == destinationState else {
            throw MediaProcessingError.destinationUnavailable(
                "the destination changed after preflight"
            )
        }
    }
}

package enum MediaDestinationState: Sendable, Equatable {
    case absent
    case existing(MediaSourceIdentity)

    package static func capture(_ url: URL) throws -> MediaDestinationState {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return .absent
        }
        return .existing(try MediaSourceIdentity.capture(url))
    }
}

public struct InspectedMediaJob: Sendable, Equatable {
    public let inputURL: URL
    public let mediaInspection: MediaAssetInspection
    public let sourceIdentity: MediaSourceIdentity
    package let mediaContext: FFmpegInspectionContext

    package init(
        inputURL: URL,
        mediaInspection: MediaAssetInspection,
        sourceIdentity: MediaSourceIdentity,
        mediaContext: FFmpegInspectionContext
    ) {
        self.inputURL = inputURL
        self.mediaInspection = mediaInspection
        self.sourceIdentity = sourceIdentity
        self.mediaContext = mediaContext
    }
}

public enum MediaJobPreparationError: Error, LocalizedError, Sendable, Equatable {
    case destinationRejected(plan: MediaOutputPlan, message: String)

    public var errorDescription: String? {
        switch self {
        case .destinationRejected(_, let message): message
        }
    }
}

public struct MediaJobPreparer: Sendable {
    public typealias DestinationPlanner = @Sendable (MediaOutputPlan) throws -> URL

    private let inspectFile: @Sendable (URL) async throws -> UnifiedMediaInspection
    private let plan: @Sendable (
        URL,
        MediaFileInfo,
        MediaProcessingOptions,
        FFmpegInspectionContext
    ) async throws -> UnifiedMediaPlan
    private let validateDestination: @Sendable (URL, MediaOutputPlan) throws -> Void

    public init() {
        self.init(engine: UnifiedFFmpegMediaEngine())
    }

    package init(engine: UnifiedFFmpegMediaEngine) {
        inspectFile = { try await engine.inspect($0) }
        plan = { url, info, options, context in
            try await engine.plan(
                inputURL: url,
                info: info,
                context: context,
                options: options
            )
        }
        validateDestination = { url, plan in
            try engine.validateOutputURL(url, for: plan)
        }
    }

    public func inspect(inputURL: URL) async throws -> InspectedMediaJob {
        try Task.checkCancellation()
        let identity = try MediaSourceIdentity.capture(inputURL)
        let mediaInspection = try await inspectFile(inputURL)
        try Task.checkCancellation()
        guard try MediaSourceIdentity.capture(inputURL) == identity else {
            throw MediaProcessingError.sourceChanged
        }
        return InspectedMediaJob(
            inputURL: inputURL,
            mediaInspection: mediaInspection.media,
            sourceIdentity: identity,
            mediaContext: mediaInspection.context
        )
    }

    public func prepare(
        inspection: InspectedMediaJob,
        selectedAudioStreamIndex: Int,
        options: MediaProcessingOptions = .standard,
        destinationPlanner: DestinationPlanner
    ) async throws -> PreparedMediaJob {
        try Task.checkCancellation()
        guard try MediaSourceIdentity.capture(inspection.inputURL) == inspection.sourceIdentity else {
            throw MediaProcessingError.sourceChanged
        }
        let info = try inspection.mediaInspection.mediaInfo(
            selectingAudioStreamIndex: selectedAudioStreamIndex
        )
        let mediaPlan = try await plan(
            inspection.inputURL, info, options, inspection.mediaContext
        )
        guard mediaPlan.inspectionContext == inspection.mediaContext else {
            throw MediaProcessingError.invalidOutputPlan(
                "media plan does not match the frozen inspection context"
            )
        }
        let outputPlan = mediaPlan.output
        let outputURL = try destinationPlanner(outputPlan)
        do {
            try validateDestination(outputURL, outputPlan)
        } catch {
            throw MediaJobPreparationError.destinationRejected(
                plan: outputPlan,
                message: error.localizedDescription
            )
        }
        guard outputURL.standardizedFileURL != inspection.inputURL.standardizedFileURL else {
            throw MediaJobPreparationError.destinationRejected(
                plan: outputPlan,
                message: "Output must be a different file from the input."
            )
        }
        let destinationState = try MediaDestinationState.capture(outputURL)
        try Task.checkCancellation()
        guard try MediaSourceIdentity.capture(inspection.inputURL) == inspection.sourceIdentity else {
            throw MediaProcessingError.sourceChanged
        }
        return PreparedMediaJob(
            inputURL: inspection.inputURL,
            outputURL: outputURL,
            inputInfo: info,
            options: options,
            sourceIdentity: inspection.sourceIdentity,
            destinationState: destinationState,
            mediaPlan: mediaPlan
        )
    }

}
