// SPDX-License-Identifier: Apache-2.0

import Foundation
import MediaIO

public enum MediaProcessingPhase: Sendable, Equatable {
    case preflight
    case enhancing
    /// Flushes the model tail and closes the replacement-media encoder.
    case finalizing
    case validating
    case committing
}

public struct MediaProcessingProgress: Sendable, Equatable {
    public let phase: MediaProcessingPhase
    public let completedWork: Int64
    public let totalWork: Int64

    public var fractionCompleted: Double {
        guard totalWork > 0 else { return phase == .committing ? 1 : 0 }
        return min(1, max(0, Double(completedWork) / Double(totalWork)))
    }

    public init(phase: MediaProcessingPhase, completedWork: Int64, totalWork: Int64) {
        self.phase = phase
        self.completedWork = completedWork
        self.totalWork = totalWork
    }
}

public struct MediaProcessingTimings: Sendable, Equatable {
    public let total: Duration
    public let preflight: Duration
    public let enhancing: Duration
    public let finalizing: Duration
    public let validating: Duration
    public let committing: Duration
    public let enhancementPass: Duration
    /// Per-channel time spent inside enhancement session `append` and
    /// `finish` calls. Media decode, encode, preview, and transaction work are
    /// excluded.
    public let channelEnhancementPasses: [Duration]

    public init(
        total: Duration,
        preflight: Duration,
        enhancing: Duration,
        finalizing: Duration,
        validating: Duration,
        committing: Duration,
        enhancementPass: Duration,
        channelEnhancementPasses: [Duration]
    ) {
        self.total = total
        self.preflight = preflight
        self.enhancing = enhancing
        self.finalizing = finalizing
        self.validating = validating
        self.committing = committing
        self.enhancementPass = enhancementPass
        self.channelEnhancementPasses = channelEnhancementPasses
    }

    public var isConsistent: Bool {
        let values = [
            total,
            preflight,
            enhancing,
            finalizing,
            validating,
            committing,
            enhancementPass,
        ]
        return values.allSatisfy { $0 >= .zero }
            && channelEnhancementPasses.allSatisfy { $0 >= .zero }
            && enhancementPass == enhancing + finalizing
            && total == preflight + enhancementPass + validating + committing
    }
}

public struct MediaProcessingResult: Sendable, Equatable {
    public let inputInfo: MediaFileInfo
    public let outputInfo: MediaFileInfo
    public let outputPlan: MediaOutputPlan
    public let notices: [MediaOutputNotice]
    public let outputURL: URL
    public let previewAssets: MediaPreviewAssets?
    public let timings: MediaProcessingTimings

    public init(
        inputInfo: MediaFileInfo,
        outputInfo: MediaFileInfo,
        outputPlan: MediaOutputPlan,
        notices: [MediaOutputNotice],
        outputURL: URL,
        previewAssets: MediaPreviewAssets? = nil,
        timings: MediaProcessingTimings
    ) {
        self.inputInfo = inputInfo
        self.outputInfo = outputInfo
        self.outputPlan = outputPlan
        self.notices = notices
        self.outputURL = outputURL
        self.previewAssets = previewAssets
        self.timings = timings
    }
}

package struct MediaProcessingClock: Sendable {
    package let now: @Sendable () -> ContinuousClock.Instant

    package init(now: @escaping @Sendable () -> ContinuousClock.Instant) {
        self.now = now
    }

    package static let continuous = Self(now: { ContinuousClock.now })
}

struct MediaProcessingTimingBoundaries: Sendable, Equatable {
    let pipelineStart: ContinuousClock.Instant
    let passStart: ContinuousClock.Instant
    let finalizingStart: ContinuousClock.Instant
    let validationStart: ContinuousClock.Instant
    let commitStart: ContinuousClock.Instant
    let pipelineEnd: ContinuousClock.Instant

    var timings: MediaProcessingTimings {
        let preflight = pipelineStart.duration(to: passStart)
        let enhancing = passStart.duration(to: finalizingStart)
        let finalizing = finalizingStart.duration(to: validationStart)
        let validating = validationStart.duration(to: commitStart)
        let committing = commitStart.duration(to: pipelineEnd)
        let enhancementPass = passStart.duration(to: validationStart)
        return MediaProcessingTimings(
            total: pipelineStart.duration(to: pipelineEnd),
            preflight: preflight,
            enhancing: enhancing,
            finalizing: finalizing,
            validating: validating,
            committing: committing,
            enhancementPass: enhancementPass,
            channelEnhancementPasses: []
        )
    }
}

public enum MediaProcessingError: Error, LocalizedError, Sendable, Equatable {
    case emptyInput
    case invalidInputLayout(String)
    case inconsistentSessionBlockSize
    case inconsistentChannelOutput
    case invalidOutputPlan(String)
    case outputIdentityChanged(String)
    case destinationUnavailable(String)
    case sourceUnavailable(String)
    case sourceChanged

    public var errorDescription: String? {
        switch self {
        case .emptyInput: return "Input audio is empty."
        case .invalidInputLayout(let value): return "Invalid input audio layout: \(value)"
        case .inconsistentSessionBlockSize:
            return "Channel sessions requested inconsistent input block sizes."
        case .inconsistentChannelOutput:
            return "Channel sessions emitted inconsistent output frame counts."
        case .invalidOutputPlan(let value):
            return "Invalid output plan: \(value)"
        case .outputIdentityChanged(let value):
            return "Enhanced output failed identity validation: \(value)"
        case .destinationUnavailable(let value):
            return "Output destination is unavailable: \(value)"
        case .sourceUnavailable(let value):
            return "Input media is unavailable: \(value)"
        case .sourceChanged:
            return "Input media changed after preflight; select the file again."
        }
    }
}
