// SPDX-License-Identifier: Apache-2.0

import Foundation

package struct FFmpegStreamRouting: Sendable, Equatable {
    package let retainedTracks: [MediaStream]
    package let selectedInputStreamIndex: Int
    package let selectedOutputStreamIndex: Int
    package let copiedStreamIndices: [Int]
    package let omittedAuxiliaryStreamIndices: [Int]

    package init(
        tracks: [MediaStream],
        selectedInputStreamIndex: Int
    ) throws {
        guard let selected = tracks.first(where: {
            $0.streamIndex == selectedInputStreamIndex
        }), selected.isAudio, selected.isUserFacing else {
            throw MediaIOError.invalidAudioStreamSelection(selectedInputStreamIndex)
        }
        let retained = tracks
            .filter(\.isUserFacing)
            .sorted { $0.streamIndex < $1.streamIndex }
        guard let selectedOutput = retained.firstIndex(where: {
            $0.streamIndex == selectedInputStreamIndex
        }) else {
            throw MediaIOError.invalidAudioStreamSelection(selectedInputStreamIndex)
        }
        retainedTracks = retained
        self.selectedInputStreamIndex = selectedInputStreamIndex
        selectedOutputStreamIndex = selectedOutput
        copiedStreamIndices = retained
            .filter { $0.streamIndex != selectedInputStreamIndex }
            .map(\.streamIndex)
        omittedAuxiliaryStreamIndices = tracks
            .filter { !$0.isUserFacing }
            .map(\.streamIndex)
    }
}

package struct UnifiedFFmpegExecutionPlan: Sendable, Equatable {
    package let inputContainer: MediaContainer
    package let outputPlan: MediaOutputPlan
    package let routing: FFmpegStreamRouting
    package let encoder: UnifiedAudioEncoder
    package let plannedBitRate: Int?

    package init(
        inputContainer: MediaContainer,
        outputPlan: MediaOutputPlan,
        routing: FFmpegStreamRouting,
        encoder: UnifiedAudioEncoder,
        plannedBitRate: Int?
    ) {
        self.inputContainer = inputContainer
        self.outputPlan = outputPlan
        self.routing = routing
        self.encoder = encoder
        self.plannedBitRate = plannedBitRate
    }
}

struct FFmpegMediaPlanBuilder {
    func build(
        info: MediaFileInfo,
        context: FFmpegInspectionContext,
        recipe: FFmpegOutputRecipe
    ) throws -> UnifiedMediaPlan {
        let routing = try FFmpegStreamRouting(
            tracks: info.tracks,
            selectedInputStreamIndex: info.selectedAudioStreamIndex
        )
        var notices: [MediaOutputNotice] = routing.omittedAuxiliaryStreamIndices.isEmpty
            ? []
            : [.auxiliaryStreamsOmitted(
                streamIndices: routing.omittedAuxiliaryStreamIndices
            )]
        if recipe.container != info.container {
            notices.append(.fallbackContainer(
                input: info.container,
                output: recipe.container
            ))
        }
        let encoding = AudioEncodingPlan(
            container: recipe.container,
            codecFormatID: recipe.encoder.formatID,
            sampleRate: info.selectedAudio.sampleRate,
            channelCount: info.selectedAudio.channelCount,
            channelLayout: info.selectedAudio.channelLayout
        )
        let output = MediaOutputPlan(
            inputContainer: info.container,
            outputContainer: recipe.container,
            audioEncoding: encoding,
            selectedAudioStreamIndex: routing.selectedInputStreamIndex,
            copiedStreamIndices: routing.copiedStreamIndices,
            omittedAuxiliaryStreamIndices: routing.omittedAuxiliaryStreamIndices,
            notices: notices
        )
        return try UnifiedMediaPlan(
            output: output,
            execution: UnifiedFFmpegExecutionPlan(
                inputContainer: info.container,
                outputPlan: output,
                routing: routing,
                encoder: recipe.encoder,
                plannedBitRate: recipe.plannedBitRate
            ),
            input: info,
            inspectionContext: context
        )
    }
}
