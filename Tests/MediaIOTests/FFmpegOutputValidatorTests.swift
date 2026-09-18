// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import XCTest
@testable import MediaIO

final class FFmpegOutputValidatorTests: XCTestCase {
    func testAcceptsReplacementCodecAndFrozenRetainedTrackOrder() throws {
        let fixture = try fixture()
        let result = try FFmpegOutputValidator().validate(
            inspection: try outputInspection(),
            request: fixture.request
        )

        XCTAssertEqual(result.outputInfo.selectedAudioStreamIndex, 1)
        XCTAssertEqual(result.resultInputInfo.selectedAudio.validFrameCount, 96_000)
    }

    func testRejectsLayoutInventoryOrderMetadataCodecAndDurationRegressions() throws {
        let request = try fixture().request
        let regressions: [UnifiedMediaInspection] = try [
            outputInspection(layout: "mono"),
            outputInspection(includeOtherAudio: false),
            outputInspection(reorderTracks: true),
            outputInspection(otherTitle: "Changed"),
            outputInspection(otherCodec: "mp3"),
            outputInspection(audioDuration: 2.2),
            outputInspection(programDuration: 2.5),
        ]

        for inspection in regressions {
            XCTAssertThrowsError(
                try FFmpegOutputValidator().validate(
                    inspection: inspection,
                    request: request
                )
            ) {
                guard case MediaIOError.invalidAudioFormat = $0 else {
                    return XCTFail("unexpected validation error: \($0)")
                }
            }
        }
    }

    private func fixture() throws -> (
        input: MediaFileInfo,
        request: UnifiedOutputValidationRequest
    ) {
        let selected = descriptor(
            codec: kAudioFormatMPEG4AAC,
            duration: 2,
            layout: "stereo"
        )
        let tracks = [
            stream(0, "vide", codec: "h264", title: "Video", dispositions: ["default"]),
            stream(2, "soun", codec: "aac", language: "eng", title: "English",
                   dispositions: ["default"]),
            stream(5, "soun", codec: "aac", language: "fra", title: "French",
                   dispositions: ["forced"]),
        ]
        let input = MediaFileInfo(
            container: .mp4,
            durationSeconds: 2,
            tracks: tracks,
            selectedAudioStreamIndex: 2,
            selectedAudio: selected,
            metadataItemCount: 0
        )
        let plan = try FFmpegMediaPlanBuilder().build(
            info: input,
            context: FFmpegInspectionContext(container: .mp4),
            recipe: FFmpegOutputRecipe(
                container: .mp4,
                encoder: .appleAAC,
                plannedBitRate: 192_000
            )
        )
        return (
            input,
            UnifiedOutputValidationRequest(
                outputURL: URL(fileURLWithPath: "/tmp/output.mp4"),
                input: input,
                plan: plan,
                enhancedFrames: 96_000
            )
        )
    }

    private func outputInspection(
        layout: String = "stereo",
        includeOtherAudio: Bool = true,
        reorderTracks: Bool = false,
        otherTitle: String = "French",
        otherCodec: String = "aac",
        audioDuration: Double = 2,
        programDuration: Double = 2
    ) throws -> UnifiedMediaInspection {
        let selected = descriptor(
            codec: kAudioFormatMPEG4AAC,
            duration: audioDuration,
            layout: layout
        )
        let other = descriptor(
            codec: otherCodec == "mp3"
                ? kAudioFormatMPEGLayer3
                : kAudioFormatMPEG4AAC,
            duration: 2,
            layout: "stereo"
        )
        let video = stream(
            reorderTracks ? 2 : 0,
            "vide",
            codec: "h264",
            title: "Video",
            dispositions: ["default"]
        )
        let selectedTrack = stream(
            1,
            "soun",
            codec: "replacement",
            language: "eng",
            title: "English",
            dispositions: ["default"]
        )
        let otherTrack = stream(
            reorderTracks ? 0 : 2,
            "soun",
            codec: otherCodec,
            language: "fra",
            title: otherTitle,
            dispositions: ["forced"]
        )
        var tracks = [video, selectedTrack]
        var audioTracks = [
            MediaAudioTrackOption(
                streamIndex: 1,
                ordinal: 1,
                title: "English",
                languageCode: "eng",
                isEnabled: true,
                isMainProgramContent: true,
                availability: .selectable(selected)
            ),
        ]
        if includeOtherAudio {
            tracks.append(otherTrack)
            audioTracks.append(
                MediaAudioTrackOption(
                    streamIndex: otherTrack.streamIndex,
                    ordinal: 2,
                    title: otherTitle,
                    languageCode: "fra",
                    isEnabled: true,
                    availability: .selectable(other)
                )
            )
        }
        let media = try MediaAssetInspection(
            container: .mp4,
            durationSeconds: programDuration,
            tracks: tracks,
            audioTracks: audioTracks,
            metadataItemCount: 0
        )
        return UnifiedMediaInspection(
            media: media,
            context: FFmpegInspectionContext(container: .mp4)
        )
    }

    private func descriptor(
        codec: AudioFormatID,
        duration: Double,
        layout: String
    ) -> AudioStreamDescriptor {
        AudioStreamDescriptor(
            sampleRate: 48_000,
            channelCount: 2,
            validFrameCount: nil,
            presentationStartSeconds: 0,
            durationSeconds: duration,
            channelLayout: AudioChannelLayoutDescriptor(
                rawData: nil,
                inferred: true,
                ffmpegName: layout
            ),
            codec: AudioCodecDescriptor(
                formatID: codec,
                fourCC: codec == kAudioFormatMPEGLayer3 ? "mp3" : "aac",
                bitsPerChannel: nil
            ),
            estimatedBitRate: 192_000
        )
    }

    private func stream(
        _ index: Int,
        _ type: String,
        codec: String,
        language: String? = nil,
        title: String?,
        dispositions: [String]
    ) -> MediaStream {
        MediaStream(
            streamIndex: index,
            mediaType: type,
            codecName: codec,
            isEnabled: true,
            languageCode: language,
            title: title,
            dispositions: dispositions,
            startSeconds: 0,
            durationSeconds: 2
        )
    }
}
