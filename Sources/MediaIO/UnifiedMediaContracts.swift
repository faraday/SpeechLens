// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct UnifiedMediaInspection: Sendable, Equatable {
    package let media: MediaAssetInspection
    package let context: FFmpegInspectionContext

    package init(media: MediaAssetInspection, context: FFmpegInspectionContext) {
        self.media = media
        self.context = context
    }

}

package struct FFmpegInspectionContext: Sendable, Equatable {
    package let container: MediaContainer
    package let containerTrackIDsByStreamIndex: [Int: Int32]

    package init(
        container: MediaContainer,
        containerTrackIDsByStreamIndex: [Int: Int32] = [:]
    ) {
        self.container = container
        self.containerTrackIDsByStreamIndex = containerTrackIDsByStreamIndex
    }
}

package struct UnifiedMediaPlan: Sendable, Equatable {
    package let output: MediaOutputPlan
    package let execution: UnifiedFFmpegExecutionPlan
    private let frozenInspectionContext: FFmpegInspectionContext

    package init(
        output: MediaOutputPlan,
        execution: UnifiedFFmpegExecutionPlan,
        input: MediaFileInfo,
        inspectionContext: FFmpegInspectionContext
    ) throws {
        guard output.inputContainer == input.container else {
            throw MediaIOError.invalidAudioFormat(
                "output plan input container does not match the selected media"
            )
        }
        guard execution.inputContainer == inspectionContext.container else {
            throw MediaIOError.invalidAudioFormat(
                "execution plan does not match the frozen inspection context"
            )
        }
        guard output.audioEncoding.sampleRate == input.selectedAudio.sampleRate,
              output.audioEncoding.channelCount == input.selectedAudio.channelCount,
              output.audioEncoding.channelLayout == input.selectedAudio.channelLayout else {
            throw MediaIOError.invalidAudioFormat(
                "output encoding changed the selected audio rate, channels, or layout"
            )
        }
        guard output == execution.outputPlan,
              input.container == execution.inputContainer,
              input.selectedAudioStreamIndex
                == execution.routing.selectedInputStreamIndex,
              output.copiedStreamIndices
                == execution.routing.copiedStreamIndices,
              output.omittedAuxiliaryStreamIndices
                == execution.routing.omittedAuxiliaryStreamIndices else {
            throw MediaIOError.invalidAudioFormat(
                "unified FFmpeg execution does not match its frozen output plan"
            )
        }
        self.output = output
        self.execution = execution
        frozenInspectionContext = inspectionContext
    }

    package var inspectionContext: FFmpegInspectionContext {
        frozenInspectionContext
    }
    package var decodedInputValidation: DecodedInputValidation {
        .decodeAuthoritative
    }
}

package enum DecodedInputValidation: Sendable, Equatable {
    case decodeAuthoritative
    case exactFrameCount(Int64)

    package func validate(actualFrameCount: Int64) throws {
        switch self {
        case .decodeAuthoritative:
            return
        case .exactFrameCount(let expected) where actualFrameCount == expected:
            return
        case .exactFrameCount(let expected):
            throw MediaIOError.readerFailed(
                "decoder emitted \(actualFrameCount) frames; stream metadata declared \(expected)"
            )
        }
    }
}

package struct UnifiedAudioSourceRequest: Sendable {
    package let url: URL
    package let info: MediaFileInfo
    package let context: FFmpegInspectionContext

    package init(
        url: URL,
        info: MediaFileInfo,
        context: FFmpegInspectionContext
    ) {
        self.url = url
        self.info = info
        self.context = context
    }
}

package struct UnifiedAudioSinkRequest: Sendable {
    package let outputURL: URL
    package let sourceURL: URL
    package let source: AudioStreamDescriptor
    package let configuration: AudioSinkConfiguration
    package let plan: UnifiedMediaPlan

    package init(
        outputURL: URL,
        sourceURL: URL,
        source: AudioStreamDescriptor,
        configuration: AudioSinkConfiguration,
        plan: UnifiedMediaPlan
    ) {
        self.outputURL = outputURL
        self.sourceURL = sourceURL
        self.source = source
        self.configuration = configuration
        self.plan = plan
    }
}

package struct UnifiedOutputValidationRequest: Sendable {
    package let outputURL: URL
    package let input: MediaFileInfo
    package let plan: UnifiedMediaPlan
    package let enhancedFrames: Int64

    package init(
        outputURL: URL,
        input: MediaFileInfo,
        plan: UnifiedMediaPlan,
        enhancedFrames: Int64
    ) {
        self.outputURL = outputURL
        self.input = input
        self.plan = plan
        self.enhancedFrames = enhancedFrames
    }
}

package struct UnifiedOutputValidation: Sendable, Equatable {
    package let outputInfo: MediaFileInfo
    package let resultInputInfo: MediaFileInfo

    package init(
        outputInfo: MediaFileInfo,
        resultInputInfo: MediaFileInfo
    ) {
        self.outputInfo = outputInfo
        self.resultInputInfo = resultInputInfo
    }
}
