// SPDX-License-Identifier: Apache-2.0

import Foundation

struct FFmpegOutputValidator {
    func validate(
        inspection: UnifiedMediaInspection,
        request: UnifiedOutputValidationRequest
    ) throws -> UnifiedOutputValidation {
        let execution = request.plan.execution
        let output = try inspection.media.mediaInfo(
            selectingAudioStreamIndex: execution.routing.selectedOutputStreamIndex
        )
        guard output.container == request.plan.output.outputContainer,
              output.selectedAudio.sampleRate == request.input.selectedAudio.sampleRate,
              output.selectedAudio.channelCount == request.input.selectedAudio.channelCount else {
            throw MediaIOError.invalidAudioFormat(
                "output changed container, sample rate, or channel count"
            )
        }
        if let expectedLayout = Self.knownLayoutName(
            request.input.selectedAudio.channelLayout
        ), output.selectedAudio.channelLayout.ffmpegName != expectedLayout {
            throw MediaIOError.invalidAudioFormat(
                "output changed the selected audio channel layout"
            )
        }
        let expectedTracks = execution.routing.retainedTracks
        let actualTracks = output.tracks
            .filter(\.isUserFacing)
            .sorted { $0.streamIndex < $1.streamIndex }
        guard actualTracks.count == expectedTracks.count else {
            throw MediaIOError.invalidAudioFormat(
                "output user-facing stream inventory changed "
                    + "(expected \(Self.streamInventory(expectedTracks)); "
                    + "actual \(Self.streamInventory(actualTracks)))"
            )
        }
        for (expected, actual) in zip(expectedTracks, actualTracks) {
            let isReplacement =
                expected.streamIndex == execution.routing.selectedInputStreamIndex
            guard expected.mediaType == actual.mediaType,
                  expected.languageCode == nil
                    || expected.languageCode == actual.languageCode,
                  expected.title == nil || expected.title == actual.title,
                  isReplacement || expected.codecName == actual.codecName,
                  Set(expected.dispositions).isSubset(
                    of: Set(actual.dispositions)
                  ) else {
                throw MediaIOError.invalidAudioFormat(
                    "output changed stream order, codec, language, title, or disposition"
                )
            }
        }
        let expectedAudioDuration = Double(request.enhancedFrames)
            / Double(request.input.selectedAudio.sampleRate)
        let codecFrames: Double = execution.encoder == .lameVBR ? 1_152 : 1_024
        // Three codec frames cover encoder priming and container timestamp
        // quantization without accepting material timeline drift.
        let durationTolerance = execution.encoder == .appleAAC
            || execution.encoder == .lameVBR
            ? 3 * codecFrames / Double(request.input.selectedAudio.sampleRate)
            : 1 / Double(request.input.selectedAudio.sampleRate)
        guard abs(output.selectedAudio.durationSeconds - expectedAudioDuration)
            <= durationTolerance else {
            throw MediaIOError.invalidAudioFormat(
                "output audio duration drifted from the enhanced PCM timeline"
            )
        }
        if request.input.isVideo {
            // Program duration metadata is often coarser than audio timestamps.
            guard abs(output.durationSeconds - request.input.durationSeconds)
                <= max(durationTolerance, 0.25) else {
                throw MediaIOError.invalidAudioFormat(
                    "output program duration changed materially"
                )
            }
        }
        return UnifiedOutputValidation(
            outputInfo: output,
            resultInputInfo: request.input.settingSelectedAudioValidFrameCount(
                request.enhancedFrames
            )
        )
    }

    private static func knownLayoutName(
        _ layout: AudioChannelLayoutDescriptor
    ) -> String? {
        guard let name = layout.ffmpegName else { return nil }
        let known: Set<String> = [
            "mono", "stereo", "2.1", "3.0", "quad", "4.0",
            "5.0", "5.1", "5.1(side)", "6.1", "7.1", "7.1(wide)",
        ]
        return known.contains(name) ? name : nil
    }

    private static func streamInventory(_ tracks: [MediaStream]) -> String {
        tracks.map {
            "\($0.streamIndex) \($0.mediaType)/\($0.codecName ?? "unknown")"
        }.joined(separator: ", ")
    }
}
