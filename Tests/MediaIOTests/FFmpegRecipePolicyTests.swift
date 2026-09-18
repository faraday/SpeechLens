// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import XCTest
@testable import MediaIO

final class FFmpegRecipePolicyTests: XCTestCase {
    private struct Signature: Equatable {
        let container: MediaContainer
        let encoder: UnifiedAudioEncoder
        let plannedBitRate: Int?

        init(
            _ container: MediaContainer,
            _ encoder: UnifiedAudioEncoder,
            _ plannedBitRate: Int?
        ) {
            self.container = container
            self.encoder = encoder
            self.plannedBitRate = plannedBitRate
        }
    }

    func testCompleteOrderedRecipeSignatures() {
        let aac = AdaptiveAACBitRate.candidateBitRates(requested: 256_000)
        let aacFrom128KMP3 = AdaptiveAACBitRate.candidateBitRates(requested: 160_000)
        let cases: [(MediaFileInfo, [Signature])] = [
            (info(.wav, kAudioFormatLinearPCM), [
                .init(.wav, .pcmF32LE, nil), .init(.caf, .pcmF32LE, nil),
            ]),
            (info(.aiff, kAudioFormatLinearPCM), [
                .init(.aiff, .pcmF32BE, nil), .init(.wav, .pcmF32LE, nil),
                .init(.caf, .pcmF32LE, nil),
            ]),
            (info(.caf, kAudioFormatLinearPCM), [
                .init(.caf, .pcmF32LE, nil),
            ]),
            (info(.flac, kAudioFormatFLAC), [
                .init(.flac, .flac24, nil), .init(.wav, .pcmF32LE, nil),
                .init(.caf, .pcmF32LE, nil),
            ]),
            (info(.mp3, kAudioFormatMPEGLayer3, bitRate: 128_000), [
                .init(.mp3, .lameVBR, 160_000),
            ] + signatures(.m4a, bitRates: aacFrom128KMP3) + [
                .init(.caf, .pcmF32LE, nil),
            ]),
            (info(.m4a, kAudioFormatMPEG4AAC), signatures(.m4a, bitRates: aac) + [
                .init(.caf, .pcmF32LE, nil),
            ]),
            (info(.mp4, kAudioFormatMPEG4AAC), signatures(
                [.mp4, .mov], bitRates: aac
            )),
            (info(.mp4, kAudioFormatAppleLossless), [
                .init(.mp4, .alac24, nil), .init(.mp4, .pcmF32LE, nil),
                .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mp4, kAudioFormatFLAC), [
                .init(.mp4, .flac24, nil), .init(.mp4, .pcmF32LE, nil),
                .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mp4, kAudioFormatLinearPCM, codecName: "pcm_s24le"), [
                .init(.mp4, .sourcePCM("pcm_s24le"), nil),
                .init(.mp4, .pcmF32LE, nil), .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mp4, 0x1234), [
                .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mov, kAudioFormatMPEG4AAC), signatures(.mov, bitRates: aac)),
            (info(.mov, kAudioFormatAppleLossless), [
                .init(.mov, .alac24, nil), .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mov, kAudioFormatFLAC), [
                .init(.mov, .alac24, nil), .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mov, kAudioFormatLinearPCM, codecName: "pcm_s24le"), [
                .init(.mov, .sourcePCM("pcm_s24le"), nil),
                .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.mov, 0x1234), [
                .init(.mov, .pcmF32LE, nil),
            ]),
            (info(.avi, kAudioFormatMPEGLayer3, bitRate: 128_000), [
                .init(.avi, .lameVBR, 160_000),
            ] + signatures(.mov, bitRates: aacFrom128KMP3)),
            (info(.avi, kAudioFormatMPEG4AAC), []),
            (info(.avi, kAudioFormatLinearPCM), [
                .init(.avi, .pcmS24LE, nil), .init(.mov, .pcmF32LE, nil),
            ]),
        ]

        for (info, expected) in cases {
            XCTAssertEqual(
                FFmpegRecipePolicy.recipes(for: info).map {
                    Signature($0.container, $0.encoder, $0.plannedBitRate)
                },
                expected,
                "\(info.container) \(info.selectedAudio.codec.formatID)"
            )
        }
    }

    func testEncoderCapabilityBoundaries() {
        for (rate, channels) in [
            (8_000, 1), (48_000, 2),
        ] {
            XCTAssertEqual(
                FFmpegRecipePolicy.recipes(
                    for: info(.mp3, kAudioFormatMPEGLayer3, rate: rate, channels: channels)
                ).first?.encoder,
                .lameVBR
            )
        }
        for (rate, channels) in [
            (7_999, 1), (48_001, 2), (48_000, 3),
        ] {
            XCTAssertFalse(
                FFmpegRecipePolicy.recipes(
                    for: info(.mp3, kAudioFormatMPEGLayer3, rate: rate, channels: channels)
                ).contains { $0.encoder == .lameVBR }
            )
        }
        for (rate, channels) in [
            (7_350, 1), (96_000, 8),
        ] {
            XCTAssertEqual(
                FFmpegRecipePolicy.recipes(
                    for: info(.m4a, kAudioFormatMPEG4AAC, rate: rate, channels: channels)
                ).first?.encoder,
                .appleAAC
            )
        }
        for (rate, channels) in [
            (7_349, 1), (96_001, 8), (96_000, 9),
        ] {
            XCTAssertFalse(
                FFmpegRecipePolicy.recipes(
                    for: info(.m4a, kAudioFormatMPEG4AAC, rate: rate, channels: channels)
                ).contains { $0.encoder == .appleAAC }
            )
        }
    }

    func testSourcePCMRecognitionAndFallbackDeduplication() {
        XCTAssertEqual(
            FFmpegRecipePolicy.recipes(
                for: info(.mov, kAudioFormatLinearPCM, codecName: "pcm_f64be")
            ).map(\.encoder),
            [.sourcePCM("pcm_f64be"), .pcmF32LE]
        )
        XCTAssertEqual(
            FFmpegRecipePolicy.recipes(
                for: info(.mov, kAudioFormatLinearPCM, codecName: "pcm_bluray")
            ).map(\.encoder),
            [.pcmF32LE]
        )
        XCTAssertEqual(
            FFmpegRecipePolicy.recipes(
                for: info(.mp4, kAudioFormatLinearPCM, codecName: "pcm_f32le")
            ).map { Signature($0.container, $0.encoder, nil) },
            [
                .init(.mp4, .sourcePCM("pcm_f32le"), nil),
                .init(.mp4, .pcmF32LE, nil),
                .init(.mov, .pcmF32LE, nil),
            ]
        )
    }

    func testWAVRepresentabilityBoundary() {
        let unknownLayout = AudioChannelLayoutDescriptor(
            rawData: nil, inferred: true, ffmpegName: nil
        )
        let knownLayout = AudioChannelLayoutDescriptor(
            rawData: nil, inferred: true, ffmpegName: "5.1"
        )
        XCTAssertEqual(
            FFmpegRecipePolicy.recipes(
                for: info(.flac, kAudioFormatFLAC, channels: 6, layout: unknownLayout)
            ).map(\.container),
            [.flac, .caf]
        )
        XCTAssertEqual(
            FFmpegRecipePolicy.recipes(
                for: info(.flac, kAudioFormatFLAC, channels: 6, layout: knownLayout)
            ).map(\.container),
            [.flac, .wav, .caf]
        )
    }

    func testPlanBuilderFreezesRoutingAndExactNotices() throws {
        let tracks = [
            track(9, "soun", codec: "aac"),
            track(2, "tmcd", codec: "tmcd"),
            track(7, "vide", codec: "h264"),
            track(1, "soun", codec: "aac"),
            track(5, "data", codec: "mjpeg", dispositions: ["attached_pic"]),
            track(3, "sbtl", codec: "mov_text"),
            track(11, "data", codec: "bin_data"),
        ]
        let info = info(
            .mp4,
            kAudioFormatMPEG4AAC,
            tracks: tracks,
            selectedStreamIndex: 9
        )
        let plan = try FFmpegMediaPlanBuilder().build(
            info: info,
            context: FFmpegInspectionContext(container: .mp4),
            recipe: FFmpegOutputRecipe(container: .mov, encoder: .appleAAC, plannedBitRate: 192_000)
        )

        XCTAssertEqual(plan.execution.routing.retainedTracks.map(\.streamIndex), [1, 3, 5, 7, 9])
        XCTAssertEqual(plan.execution.routing.selectedInputStreamIndex, 9)
        XCTAssertEqual(plan.execution.routing.selectedOutputStreamIndex, 4)
        XCTAssertEqual(plan.execution.routing.copiedStreamIndices, [1, 3, 5, 7])
        XCTAssertEqual(plan.execution.routing.omittedAuxiliaryStreamIndices, [2, 11])
        XCTAssertEqual(plan.output.copiedStreamIndices, [1, 3, 5, 7])
        XCTAssertEqual(plan.output.omittedAuxiliaryStreamIndices, [2, 11])
        XCTAssertEqual(plan.output.audioEncoding.sampleRate, 48_000)
        XCTAssertEqual(plan.output.audioEncoding.channelCount, 2)
        XCTAssertEqual(plan.output.audioEncoding.channelLayout, info.selectedAudio.channelLayout)
        XCTAssertEqual(plan.output.notices, [
            .auxiliaryStreamsOmitted(streamIndices: [2, 11]),
            .fallbackContainer(input: .mp4, output: .mov),
        ])
    }

    func testFallbackNoticeAppearsOnlyWhenContainerChanges() throws {
        let info = info(.wav, kAudioFormatLinearPCM)
        let context = FFmpegInspectionContext(container: .wav)
        let same = try FFmpegMediaPlanBuilder().build(
            info: info,
            context: context,
            recipe: FFmpegOutputRecipe(container: .wav, encoder: .pcmF32LE)
        )
        let fallback = try FFmpegMediaPlanBuilder().build(
            info: info,
            context: context,
            recipe: FFmpegOutputRecipe(container: .caf, encoder: .pcmF32LE)
        )
        XCTAssertEqual(same.output.notices, [])
        XCTAssertEqual(fallback.output.notices, [
            .fallbackContainer(input: .wav, output: .caf)
        ])
    }

    func testRoutingRejectsInvalidSelectedStreams() {
        let tracks = [
            track(1, "soun", codec: "aac"),
            track(3, "vide", codec: "h264"),
            track(5, "data", codec: "bin_data"),
        ]
        for index in [2, 3, 5] {
            XCTAssertThrowsError(
                try FFmpegStreamRouting(
                    tracks: tracks,
                    selectedInputStreamIndex: index
                )
            ) {
                XCTAssertEqual(
                    $0 as? MediaIOError,
                    .invalidAudioStreamSelection(index)
                )
            }
        }
    }

    func testEncoderAndContainerOwnFFmpegInvocationFacts() {
        XCTAssertEqual(UnifiedAudioEncoder.pcmF32LE.ffmpegName, "pcm_f32le")
        XCTAssertEqual(UnifiedAudioEncoder.sourcePCM("pcm_s24be").ffmpegName, "pcm_s24be")
        XCTAssertEqual(
            UnifiedAudioEncoder.flac24.ffmpegArguments(plannedBitRate: nil),
            ["-compression_level", "5", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
        )
        XCTAssertEqual(
            UnifiedAudioEncoder.appleAAC.ffmpegArguments(plannedBitRate: 192_000),
            ["-aac_at_mode", "abr", "-b:a", "192000"]
        )
        XCTAssertEqual(MediaContainer.m4a.ffmpegMuxerName, "mp4")
        XCTAssertEqual(MediaContainer.mov.ffmpegMuxerName, "mov")
    }

    private func signatures(
        _ container: MediaContainer,
        bitRates: [Int]
    ) -> [Signature] {
        signatures([container], bitRates: bitRates)
    }

    private func signatures(
        _ containers: [MediaContainer],
        bitRates: [Int]
    ) -> [Signature] {
        containers.flatMap { container in
            bitRates.map { Signature(container, .appleAAC, $0) }
        }
    }

    private func info(
        _ container: MediaContainer,
        _ codec: AudioFormatID,
        bitRate: Int? = nil,
        codecName: String? = nil,
        rate: Int = 48_000,
        channels: Int = 2,
        layout: AudioChannelLayoutDescriptor? = nil,
        tracks: [MediaStream]? = nil,
        selectedStreamIndex: Int = 1
    ) -> MediaFileInfo {
        let name = codecName ?? (codec == kAudioFormatLinearPCM ? "pcm_f32le" : "audio")
        let audio = AudioStreamDescriptor(
            sampleRate: rate,
            channelCount: channels,
            validFrameCount: nil,
            presentationStartSeconds: 0,
            durationSeconds: 1,
            channelLayout: layout ?? AudioChannelLayoutDescriptor(
                rawData: nil,
                inferred: true,
                ffmpegName: channels == 1 ? "mono" : (channels == 2 ? "stereo" : nil)
            ),
            codec: AudioCodecDescriptor(
                formatID: codec,
                fourCC: name,
                bitsPerChannel: nil
            ),
            estimatedBitRate: bitRate
        )
        return MediaFileInfo(
            container: container,
            durationSeconds: 1,
            tracks: tracks ?? [track(selectedStreamIndex, "soun", codec: name)],
            selectedAudioStreamIndex: selectedStreamIndex,
            selectedAudio: audio,
            metadataItemCount: 0
        )
    }

    private func track(
        _ index: Int,
        _ type: String,
        codec: String,
        dispositions: [String] = []
    ) -> MediaStream {
        MediaStream(
            streamIndex: index,
            mediaType: type,
            codecName: codec,
            isEnabled: true,
            languageCode: type == "soun" ? "eng" : nil,
            dispositions: dispositions,
            startSeconds: 0,
            durationSeconds: 1
        )
    }
}
