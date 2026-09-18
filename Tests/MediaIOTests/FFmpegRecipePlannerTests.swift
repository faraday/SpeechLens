// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import XCTest
@testable import MediaIO

final class FFmpegRecipePlannerTests: XCTestCase {
    func testEverySupportedContainerUsesFFmpeg() {
        for container in MediaContainer.allCases {
            XCTAssertEqual(
                FFmpegRecipePlanner(inputContainer: container).inputContainer,
                container
            )
        }
    }

    func testCanonicalRecipeMatrix() throws {
        let cases: [(MediaContainer, AudioFormatID, Int?, MediaContainer, UnifiedAudioEncoder, Int?)] = [
            (.wav, kAudioFormatLinearPCM, nil, .wav, .pcmF32LE, nil),
            (.aiff, kAudioFormatLinearPCM, nil, .aiff, .pcmF32BE, nil),
            (.caf, kAudioFormatLinearPCM, nil, .caf, .pcmF32LE, nil),
            (.flac, kAudioFormatFLAC, nil, .flac, .flac24, nil),
            (.mp3, kAudioFormatMPEGLayer3, 128_000, .mp3, .lameVBR, 160_000),
            (.m4a, kAudioFormatMPEG4AAC, nil, .m4a, .appleAAC, 256_000),
            (.mp4, kAudioFormatMPEG4AAC, 128_000, .mp4, .appleAAC, 128_000),
            (.mp4, kAudioFormatAppleLossless, nil, .mp4, .alac24, nil),
            (.mp4, kAudioFormatFLAC, nil, .mp4, .flac24, nil),
            (.mp4, kAudioFormatLinearPCM, nil, .mp4, .sourcePCM("pcm_f32le"), nil),
            (.mov, kAudioFormatMPEG4AAC, 192_000, .mov, .appleAAC, 192_000),
            (.mov, kAudioFormatAppleLossless, nil, .mov, .alac24, nil),
            (.mov, kAudioFormatFLAC, nil, .mov, .alac24, nil),
            (.mov, kAudioFormatLinearPCM, nil, .mov, .sourcePCM("pcm_f32le"), nil),
            (.avi, kAudioFormatMPEGLayer3, 128_000, .avi, .lameVBR, 160_000),
            (.avi, kAudioFormatLinearPCM, nil, .avi, .pcmS24LE, nil),
        ]
        for (container, codec, bitRate, expectedContainer, expectedEncoder, expectedBitRate) in cases {
            let plans = try FFmpegRecipePlanner(
                inputContainer: container
            ).plans(
                info: info(container: container, codec: codec, bitRate: bitRate),
                context: FFmpegInspectionContext(container: container)
            )
            let backend = try XCTUnwrap(plans.first)
            XCTAssertEqual(backend.output.outputContainer, expectedContainer)
            XCTAssertEqual(backend.execution.encoder, expectedEncoder)
            XCTAssertEqual(backend.execution.plannedBitRate, expectedBitRate)
            XCTAssertEqual(backend.output.audioEncoding.sampleRate, 48_000)
        }
    }

    func testAdaptiveMP3BitRateBoundariesAndLowRateClamp() {
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: nil, sampleRate: 44_100), 192_000)
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: 128_000, sampleRate: 44_100), 160_000)
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: 192_000, sampleRate: 44_100), 192_000)
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: 256_000, sampleRate: 44_100), 256_000)
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: 257_000, sampleRate: 44_100), 320_000)
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: 320_000, sampleRate: 16_000), 160_000)
        XCTAssertEqual(AdaptiveMP3BitRate.requestedBitRate(forSourceBitRate: nil, sampleRate: 8_000), 56_000)
    }

    func testAdaptiveAACBitRateUsesExactThenNextHigherThenHighest() {
        XCTAssertEqual(AdaptiveAACBitRate.selectSupportedBitRate(requested: 128_000), 128_000)
        XCTAssertEqual(AdaptiveAACBitRate.selectSupportedBitRate(requested: 150_000), 160_000)
        XCTAssertEqual(AdaptiveAACBitRate.selectSupportedBitRate(requested: 500_000), 320_000)
        XCTAssertEqual(
            AdaptiveAACBitRate.requestedBitRate(source: info(
                container: .m4a,
                codec: kAudioFormatMPEG4AAC
            ).selectedAudio),
            256_000
        )
    }

    func testAdaptiveAACBitRateCandidatesStepDownFromRequestedTarget() {
        XCTAssertEqual(
            AdaptiveAACBitRate.candidateBitRates(requested: 150_000),
            [160_000, 144_000, 128_000, 112_000, 96_000, 80_000, 64_000,
             56_000, 48_000, 40_000, 32_000]
        )
        XCTAssertEqual(
            AdaptiveAACBitRate.candidateBitRates(requested: 500_000),
            [320_000, 288_000, 256_000, 224_000, 192_000, 160_000,
             144_000, 128_000, 112_000, 96_000, 80_000, 64_000, 56_000,
             48_000, 40_000, 32_000]
        )
    }

    func testFallbackRecipesAreResolvedBeforeInference() throws {
        let cases: [(MediaContainer, AudioFormatID, [MediaContainer])] = [
            (.aiff, kAudioFormatLinearPCM, [.aiff, .wav, .caf]),
            (.flac, kAudioFormatFLAC, [.flac, .wav, .caf]),
            (.mp3, kAudioFormatMPEGLayer3, [.mp3, .m4a, .caf]),
            (.m4a, kAudioFormatMPEG4AAC, [.m4a, .caf]),
            (.mp4, kAudioFormatMPEG4AAC, [.mp4, .mov]),
            (.avi, kAudioFormatMPEGLayer3, [.avi, .mov]),
        ]
        for (container, codec, expected) in cases {
            let plans = try FFmpegRecipePlanner(
                inputContainer: container
            ).plans(
                info: info(container: container, codec: codec),
                context: FFmpegInspectionContext(container: container)
            )
            let containers = plans.map(\.output.outputContainer).reduce(into: [MediaContainer]()) {
                if $0.last != $1 { $0.append($1) }
            }
            XCTAssertEqual(containers, expected)
            XCTAssertTrue(plans.allSatisfy {
                $0.output.audioEncoding.sampleRate == 48_000
            })
        }
    }

    func testLosslessMOVAndMP4RecipeOrder() throws {
        struct ExpectedRecipe: Equatable {
            let container: MediaContainer
            let encoder: UnifiedAudioEncoder
        }
        let cases: [(MediaContainer, AudioFormatID, String?, [ExpectedRecipe])] = [
            (.mov, kAudioFormatAppleLossless, nil, [
                .init(container: .mov, encoder: .alac24),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mov, kAudioFormatFLAC, nil, [
                .init(container: .mov, encoder: .alac24),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mov, kAudioFormatLinearPCM, "pcm_s24le", [
                .init(container: .mov, encoder: .sourcePCM("pcm_s24le")),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mov, kAudioFormatLinearPCM, "pcm_bluray", [
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mp4, kAudioFormatAppleLossless, nil, [
                .init(container: .mp4, encoder: .alac24),
                .init(container: .mp4, encoder: .pcmF32LE),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mp4, kAudioFormatFLAC, nil, [
                .init(container: .mp4, encoder: .flac24),
                .init(container: .mp4, encoder: .pcmF32LE),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mp4, kAudioFormatLinearPCM, "pcm_s24le", [
                .init(container: .mp4, encoder: .sourcePCM("pcm_s24le")),
                .init(container: .mp4, encoder: .pcmF32LE),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
            (.mp4, kAudioFormatLinearPCM, "pcm_bluray", [
                .init(container: .mp4, encoder: .pcmF32LE),
                .init(container: .mov, encoder: .pcmF32LE),
            ]),
        ]
        for (container, codec, codecName, expected) in cases {
            let plans = try FFmpegRecipePlanner(inputContainer: container).plans(
                info: info(container: container, codec: codec, codecName: codecName),
                context: FFmpegInspectionContext(container: container)
            )
            XCTAssertEqual(plans.map {
                ExpectedRecipe(
                    container: $0.output.outputContainer,
                    encoder: $0.execution.encoder
                )
            }, expected)
        }
    }

    private func info(
        container: MediaContainer,
        codec: AudioFormatID,
        bitRate: Int? = nil,
        codecName: String? = nil
    ) -> MediaFileInfo {
        let audio = AudioStreamDescriptor(
            sampleRate: 48_000,
            channelCount: 2,
            validFrameCount: nil,
            presentationStartSeconds: 0,
            durationSeconds: 1,
            channelLayout: AudioChannelLayoutDescriptor(rawData: nil, inferred: true),
            codec: AudioCodecDescriptor(
                formatID: codec,
                fourCC: codecName ?? (codec == kAudioFormatLinearPCM ? "pcm_f32le" : "audio"),
                bitsPerChannel: nil
            ),
            estimatedBitRate: bitRate
        )
        return MediaFileInfo(
            container: container,
            durationSeconds: 1,
            tracks: [
                MediaStream(
                    streamIndex: 1,
                    mediaType: "soun",
                    codecName: codecName ?? (codec == kAudioFormatLinearPCM ? "pcm_f32le" : nil),
                    isEnabled: true,
                    languageCode: "eng",
                    startSeconds: 0,
                    durationSeconds: 1
                ),
            ],
            selectedAudioStreamIndex: 1,
            selectedAudio: audio,
            metadataItemCount: 0
        )
    }
}
