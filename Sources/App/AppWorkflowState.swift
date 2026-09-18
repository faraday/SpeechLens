// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Diagnostics
import Foundation
import Inference
import MediaIO
import Processing

struct PendingMediaJob: Sendable, Equatable {
    let inputURL: URL
    let outputURL: URL?

    init(inputURL: URL, outputURL: URL? = nil) {
        self.inputURL = inputURL
        self.outputURL = outputURL
    }
}

struct MediaProcessingRequest: Sendable, Equatable {
    let job: PendingMediaJob
    let settings: InferenceSettings
    let options: MediaProcessingOptions
    let weightsURL: URL
    let mode: InferenceMode

    init(
        job: PendingMediaJob,
        settings: InferenceSettings,
        options: MediaProcessingOptions,
        weightsURL: URL,
        mode: InferenceMode = .standard
    ) {
        self.job = job
        self.settings = settings
        self.options = options
        self.weightsURL = weightsURL
        self.mode = mode
    }
}

struct MediaJobContext: Sendable, Equatable {
    let job: PendingMediaJob
    let preparedJob: PreparedMediaJob
    let info: AppInspectedMedia
    let notices: [MediaOutputNotice]
    let processingDurationSeconds: Double?

    init(
        job: PendingMediaJob,
        preparedJob: PreparedMediaJob,
        info: AppInspectedMedia,
        notices: [MediaOutputNotice] = [],
        processingDurationSeconds: Double? = nil
    ) {
        self.job = job
        self.preparedJob = preparedJob
        self.info = info
        self.notices = notices
        self.processingDurationSeconds = processingDurationSeconds
    }

    var inputURL: URL { job.inputURL }
    var outputURL: URL { preparedJob.outputURL }
    var hasWarnings: Bool {
        notices.contains { $0.severity == .warning }
    }
}

struct AudioTrackSelectionContext: Sendable, Equatable {
    let request: MediaProcessingRequest
    let inspection: InspectedMediaJob
    var selectedStreamIndex: Int

    var selectedTrack: MediaAudioTrackOption? {
        inspection.mediaInspection.audioTracks.first {
            $0.streamIndex == selectedStreamIndex
        }
    }
}

struct AppWorkflowFailure: Sendable, Equatable {
    let category: DiagnosticFailureCategory
    let code: DiagnosticFailureCode
    let technicalDetail: String?
    let job: PendingMediaJob?
    let info: AudioFileInfo?
}

enum AppWorkflowState: Sendable, Equatable {
    case idle
    case preparing(PendingMediaJob)
    case selectingAudioTrack(AudioTrackSelectionContext)
    case loadingModel(MediaJobContext)
    case processing(MediaJobContext, MediaProcessingProgress)
    case completed(MediaJobContext)
    case cancelled(PendingMediaJob, AudioFileInfo?)
    case failed(AppWorkflowFailure)

    var isBusy: Bool {
        switch self {
        case .preparing, .loadingModel, .processing:
            return true
        default:
            return false
        }
    }

    var locksInputAndSettings: Bool {
        isBusy || isSelectingAudioTrack
    }

    var isSelectingAudioTrack: Bool {
        if case .selectingAudioTrack = self { return true }
        return false
    }

    var selectedInputURL: URL? { pendingJob?.inputURL }
    var plannedOutputURL: URL? { pendingJob?.outputURL }

    var audioInfo: AudioFileInfo? {
        switch self {
        case .selectingAudioTrack(let context):
            return context.selectedTrack?.audioDescriptor?.audioFileInfo
        case .loadingModel(let context), .processing(let context, _), .completed(let context):
            return context.info.audioInfo
        case .cancelled(_, let info):
            return info
        case .failed(let failure):
            return failure.info
        case .idle, .preparing:
            return nil
        }
    }

    var mediaInfo: MediaFileInfo? {
        switch self {
        case .loadingModel(let context), .processing(let context, _), .completed(let context):
            return context.info.mediaInfo
        default:
            return nil
        }
    }

    var outputPlan: MediaOutputPlan? {
        switch self {
        case .loadingModel(let context), .processing(let context, _), .completed(let context):
            return context.info.outputPlan
        default:
            return nil
        }
    }

    var completedContext: MediaJobContext? {
        guard case .completed(let context) = self else { return nil }
        return context
    }

    var progress: MediaProcessingProgress? {
        guard case .processing(_, let progress) = self else { return nil }
        return progress
    }

    private var pendingJob: PendingMediaJob? {
        switch self {
        case .selectingAudioTrack(let context):
            return context.request.job
        case .preparing(let job), .cancelled(let job, _):
            return job
        case .loadingModel(let context), .processing(let context, _), .completed(let context):
            return context.job
        case .failed(let failure):
            return failure.job
        case .idle:
            return nil
        }
    }
}

enum AppPendingAction: Sendable, Equatable {
    case choosingMedia
    case downloadingModel
}
