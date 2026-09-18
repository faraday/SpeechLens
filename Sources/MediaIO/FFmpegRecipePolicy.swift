// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation

package enum UnifiedAudioEncoder: Sendable, Equatable {
    case pcmF32LE
    case pcmF32BE
    case pcmS24LE
    case sourcePCM(String)
    case flac24
    case alac24
    case lameVBR
    case appleAAC

    package var formatID: AudioFormatID {
        switch self {
        case .pcmF32LE, .pcmF32BE, .pcmS24LE, .sourcePCM: kAudioFormatLinearPCM
        case .flac24: kAudioFormatFLAC
        case .alac24: kAudioFormatAppleLossless
        case .lameVBR: kAudioFormatMPEGLayer3
        case .appleAAC: kAudioFormatMPEG4AAC
        }
    }

    package var ffmpegName: String {
        switch self {
        case .pcmF32LE: "pcm_f32le"
        case .pcmF32BE: "pcm_f32be"
        case .pcmS24LE: "pcm_s24le"
        case .sourcePCM(let codecName): codecName
        case .flac24: "flac"
        case .alac24: "alac"
        case .lameVBR: "libmp3lame"
        case .appleAAC: "aac_at"
        }
    }

    package func ffmpegArguments(plannedBitRate: Int?) -> [String] {
        switch self {
        case .flac24:
            ["-compression_level", "5", "-sample_fmt", "s32", "-bits_per_raw_sample", "24"]
        case .lameVBR:
            ["-b:a", String(plannedBitRate ?? 192_000)]
        case .appleAAC:
            ["-aac_at_mode", "abr", "-b:a", String(plannedBitRate ?? 256_000)]
        default:
            []
        }
    }

    static func sourcePCM(codecName: String?) -> UnifiedAudioEncoder? {
        guard let codecName, supportedPCMCodecNames.contains(codecName) else {
            return nil
        }
        return .sourcePCM(codecName)
    }

    private static let supportedPCMCodecNames: Set<String> = [
        "pcm_u8",
        "pcm_s16le", "pcm_s16be",
        "pcm_s24le", "pcm_s24be",
        "pcm_s32le", "pcm_s32be",
        "pcm_f32le", "pcm_f32be",
        "pcm_f64le", "pcm_f64be",
    ]
}

package extension MediaContainer {
    var ffmpegMuxerName: String {
        switch self {
        case .m4a, .mp4: "mp4"
        default: rawValue
        }
    }
}

package enum AdaptiveMP3BitRate {
    package static func requestedBitRate(
        forSourceBitRate bitRate: Int?,
        sampleRate: Int
    ) -> Int {
        let selected: Int
        guard let bitRate, bitRate > 0 else {
            selected = 192_000
            return constrained(selected, for: sampleRate)
        }
        if bitRate <= 128_000 { selected = 160_000 }
        else if bitRate <= 192_000 { selected = 192_000 }
        else if bitRate <= 256_000 { selected = 256_000 }
        else { selected = 320_000 }
        return constrained(selected, for: sampleRate)
    }

    private static func constrained(_ bitRate: Int, for sampleRate: Int) -> Int {
        if sampleRate <= 12_000 { return min(bitRate, 56_000) }
        if sampleRate <= 24_000 { return min(bitRate, 160_000) }
        return bitRate
    }
}

package enum AdaptiveAACBitRate {
    private static let standardBitRates = [
        32_000, 40_000, 48_000, 56_000, 64_000, 80_000, 96_000, 112_000,
        128_000, 144_000, 160_000, 192_000, 224_000, 256_000, 288_000, 320_000,
    ]

    package static func requestedBitRate(source: AudioStreamDescriptor) -> Int {
        let requested: Int
        switch source.codec.formatID {
        case kAudioFormatMPEGLayer3:
            let bitRate = source.estimatedBitRate
            if let bitRate, bitRate > 0, bitRate <= 128_000 { requested = 160_000 }
            else if let bitRate, bitRate > 0, bitRate <= 192_000 { requested = 192_000 }
            else { requested = 256_000 }
        case kAudioFormatMPEG4AAC:
            requested = source.estimatedBitRate.flatMap { $0 > 0 ? $0 : nil } ?? 256_000
        default:
            requested = 256_000
        }
        return selectSupportedBitRate(requested: requested)
    }

    package static func selectSupportedBitRate(requested: Int) -> Int {
        if standardBitRates.contains(requested) { return requested }
        return standardBitRates.first(where: { $0 > requested }) ?? standardBitRates.last!
    }

    package static func candidateBitRates(requested: Int) -> [Int] {
        let initial = selectSupportedBitRate(requested: requested)
        return standardBitRates.filter { $0 <= initial }.reversed()
    }
}

package struct FFmpegOutputRecipe: Sendable, Equatable {
    package let container: MediaContainer
    package let encoder: UnifiedAudioEncoder
    package let plannedBitRate: Int?

    package init(
        container: MediaContainer,
        encoder: UnifiedAudioEncoder,
        plannedBitRate: Int? = nil
    ) {
        self.container = container
        self.encoder = encoder
        self.plannedBitRate = plannedBitRate
    }
}

package enum FFmpegRecipePolicy {
    package static func recipes(for info: MediaFileInfo) -> [FFmpegOutputRecipe] {
        let lossy = info.selectedAudio.codec.formatID == kAudioFormatMPEGLayer3
            || info.selectedAudio.codec.formatID == kAudioFormatMPEG4AAC
        let supportsAAC = supportsAppleAAC(info.selectedAudio)
        let supportsMP3 = supportsLAME(info.selectedAudio)
        let sourcePCM = UnifiedAudioEncoder.sourcePCM(
            codecName: info.tracks.first(where: {
                $0.streamIndex == info.selectedAudioStreamIndex
            })?.codecName
        )
        let mp3BitRate = AdaptiveMP3BitRate.requestedBitRate(
            forSourceBitRate: info.selectedAudio.estimatedBitRate,
            sampleRate: info.selectedAudio.sampleRate
        )
        let aacBitRates = AdaptiveAACBitRate.candidateBitRates(
            requested: AdaptiveAACBitRate.requestedBitRate(source: info.selectedAudio)
        )
        let recipes: [FFmpegOutputRecipe] = switch info.container {
        case .wav:
            [.init(container: .wav, encoder: .pcmF32LE),
             .init(container: .caf, encoder: .pcmF32LE)]
        case .aiff:
            [.init(container: .aiff, encoder: .pcmF32BE)]
                + (wavCanRepresent(info.selectedAudio)
                    ? [.init(container: .wav, encoder: .pcmF32LE)] : [])
                + [.init(container: .caf, encoder: .pcmF32LE)]
        case .caf:
            [.init(container: .caf, encoder: .pcmF32LE)]
        case .flac:
            [.init(container: .flac, encoder: .flac24)]
                + (wavCanRepresent(info.selectedAudio)
                    ? [.init(container: .wav, encoder: .pcmF32LE)] : [])
                + [.init(container: .caf, encoder: .pcmF32LE)]
        case .mp3:
            (supportsMP3 ? [.init(
                container: .mp3,
                encoder: .lameVBR,
                plannedBitRate: mp3BitRate
            )] : [])
                + (supportsAAC ? aacRecipes(containers: [.m4a], bitRates: aacBitRates) : [])
                + [.init(container: .caf, encoder: .pcmF32LE)]
        case .m4a:
            (supportsAAC ? aacRecipes(containers: [.m4a], bitRates: aacBitRates) : [])
                + [.init(container: .caf, encoder: .pcmF32LE)]
        case .mp4:
            switch info.selectedAudio.codec.formatID {
            case let format where supportsAAC && (
                format == kAudioFormatMPEGLayer3 || format == kAudioFormatMPEG4AAC
            ):
                aacRecipes(containers: [.mp4, .mov], bitRates: aacBitRates)
            case kAudioFormatAppleLossless:
                [.init(container: .mp4, encoder: .alac24),
                 .init(container: .mp4, encoder: .pcmF32LE),
                 .init(container: .mov, encoder: .pcmF32LE)]
            case kAudioFormatFLAC:
                [.init(container: .mp4, encoder: .flac24),
                 .init(container: .mp4, encoder: .pcmF32LE),
                 .init(container: .mov, encoder: .pcmF32LE)]
            case kAudioFormatLinearPCM:
                (sourcePCM.map { [.init(container: .mp4, encoder: $0)] } ?? [])
                    + [.init(container: .mp4, encoder: .pcmF32LE),
                       .init(container: .mov, encoder: .pcmF32LE)]
            default:
                [.init(container: .mov, encoder: .pcmF32LE)]
            }
        case .mov:
            switch info.selectedAudio.codec.formatID {
            case let format where supportsAAC && (
                format == kAudioFormatMPEGLayer3 || format == kAudioFormatMPEG4AAC
            ):
                aacRecipes(containers: [.mov], bitRates: aacBitRates)
            case kAudioFormatAppleLossless, kAudioFormatFLAC:
                [.init(container: .mov, encoder: .alac24),
                 .init(container: .mov, encoder: .pcmF32LE)]
            case kAudioFormatLinearPCM:
                (sourcePCM.map { [.init(container: .mov, encoder: $0)] } ?? [])
                    + [.init(container: .mov, encoder: .pcmF32LE)]
            default:
                [.init(container: .mov, encoder: .pcmF32LE)]
            }
        case .avi:
            switch info.selectedAudio.codec.formatID {
            case kAudioFormatMPEGLayer3 where supportsMP3:
                [.init(
                    container: .avi,
                    encoder: .lameVBR,
                    plannedBitRate: mp3BitRate
                )] + (lossy && supportsAAC
                    ? aacRecipes(containers: [.mov], bitRates: aacBitRates)
                    : [.init(container: .mov, encoder: .pcmF32LE)])
            case kAudioFormatMPEG4AAC:
                []
            default:
                [.init(container: .avi, encoder: .pcmS24LE)]
                    + (lossy && supportsAAC
                        ? aacRecipes(containers: [.mov], bitRates: aacBitRates)
                        : [.init(container: .mov, encoder: .pcmF32LE)])
            }
        }
        var unique: [FFmpegOutputRecipe] = []
        for recipe in recipes where !unique.contains(recipe) {
            unique.append(recipe)
        }
        return unique
    }

    private static func wavCanRepresent(_ audio: AudioStreamDescriptor) -> Bool {
        audio.channelCount <= 2 || audio.channelLayout.ffmpegName != nil
    }

    private static func aacRecipes(
        containers: [MediaContainer],
        bitRates: [Int]
    ) -> [FFmpegOutputRecipe] {
        containers.flatMap { container in
            bitRates.map {
                .init(container: container, encoder: .appleAAC, plannedBitRate: $0)
            }
        }
    }

    private static func supportsLAME(_ audio: AudioStreamDescriptor) -> Bool {
        let rates: Set<Int> = [
            8_000, 11_025, 12_000, 16_000, 22_050,
            24_000, 32_000, 44_100, 48_000,
        ]
        return rates.contains(audio.sampleRate) && (1...2).contains(audio.channelCount)
    }

    private static func supportsAppleAAC(_ audio: AudioStreamDescriptor) -> Bool {
        let rates: Set<Int> = [
            7_350, 8_000, 11_025, 12_000, 16_000, 22_050,
            24_000, 32_000, 44_100, 48_000, 64_000, 88_200, 96_000,
        ]
        return rates.contains(audio.sampleRate) && (1...8).contains(audio.channelCount)
    }
}
