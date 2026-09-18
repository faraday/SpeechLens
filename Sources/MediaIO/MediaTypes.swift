// SPDX-License-Identifier: Apache-2.0

import AudioIO
import AudioToolbox
import Foundation

public enum MediaContainer: String, CaseIterable, Sendable, Equatable {
    case wav
    case aiff
    case caf
    case mp3
    case m4a
    case mp4
    case mov
    case avi
    case flac

    public static func from(pathExtension: String) -> MediaContainer? {
        switch pathExtension.lowercased() {
        case "wav", "wave": return .wav
        case "aif", "aiff", "aifc": return .aiff
        case "caf", "caff": return .caf
        case "mp3": return .mp3
        case "m4a", "m4r": return .m4a
        case "mp4", "m4v": return .mp4
        case "mov", "qt": return .mov
        case "avi": return .avi
        case "flac": return .flac
        default: return nil
        }
    }

    public var preferredExtension: String {
        switch self {
        case .aiff: "aiff"
        default: rawValue
        }
    }

    public var isVideoContainer: Bool { self == .mp4 || self == .mov || self == .avi }

    var ffprobeFormatNames: [String] {
        switch self {
        case .m4a, .mp4, .mov:
            ["mov"]
        default:
            [rawValue]
        }
    }
}

public enum MediaPreviewPolicy: Sendable, Equatable {
    case none
    case retainAudioAndWaveforms
}

public struct MediaProcessingOptions: Sendable, Equatable {
    public let previewPolicy: MediaPreviewPolicy

    public static let standard = MediaProcessingOptions(
        previewPolicy: .none
    )

    public init(
        previewPolicy: MediaPreviewPolicy = .none
    ) {
        self.previewPolicy = previewPolicy
    }
}

public struct AudioEncodingPlan: Sendable, Equatable {
    public let container: MediaContainer
    public let codecFormatID: UInt32
    public let sampleRate: Int
    public let channelCount: Int
    public let channelLayout: AudioChannelLayoutDescriptor

    public init(
        container: MediaContainer,
        codecFormatID: UInt32,
        sampleRate: Int,
        channelCount: Int,
        channelLayout: AudioChannelLayoutDescriptor
    ) {
        self.container = container
        self.codecFormatID = codecFormatID
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.channelLayout = channelLayout
    }
}

public struct MediaOutputPlan: Sendable, Equatable {
    public let inputContainer: MediaContainer
    public let outputContainer: MediaContainer
    public let audioEncoding: AudioEncodingPlan
    public let selectedAudioStreamIndex: Int
    public let copiedStreamIndices: [Int]
    public let omittedAuxiliaryStreamIndices: [Int]
    public let notices: [MediaOutputNotice]

    public var usesFallbackContainer: Bool { inputContainer != outputContainer }

    public init(
        inputContainer: MediaContainer,
        outputContainer: MediaContainer,
        audioEncoding: AudioEncodingPlan,
        selectedAudioStreamIndex: Int,
        copiedStreamIndices: [Int],
        omittedAuxiliaryStreamIndices: [Int] = [],
        notices: [MediaOutputNotice] = []
    ) {
        self.inputContainer = inputContainer
        self.outputContainer = outputContainer
        self.audioEncoding = audioEncoding
        self.selectedAudioStreamIndex = selectedAudioStreamIndex
        self.copiedStreamIndices = copiedStreamIndices
        self.omittedAuxiliaryStreamIndices = omittedAuxiliaryStreamIndices
        self.notices = notices
    }
}

public enum MediaOutputNoticeSeverity: String, Codable, Sendable, Equatable {
    case information
    case warning
}

public enum MediaOutputNotice: Sendable, Equatable {
    case auxiliaryStreamsOmitted(streamIndices: [Int])
    case fallbackContainer(input: MediaContainer, output: MediaContainer)

    public var severity: MediaOutputNoticeSeverity {
        switch self {
        case .auxiliaryStreamsOmitted:
            return .warning
        case .fallbackContainer:
            return .information
        }
    }
}

public struct AudioChannelLayoutDescriptor: Sendable, Equatable {
    public let rawData: Data?
    public let inferred: Bool
    public let ffmpegName: String?

    public init(
        rawData: Data?,
        inferred: Bool = false,
        ffmpegName: String? = nil
    ) {
        self.rawData = rawData
        self.inferred = inferred
        self.ffmpegName = ffmpegName
    }
}

public struct AudioCodecDescriptor: Sendable, Equatable {
    public let formatID: UInt32
    public let formatFlags: UInt32
    public let fourCC: String
    public let bitsPerChannel: Int?

    public init(
        formatID: UInt32,
        formatFlags: UInt32 = 0,
        fourCC: String,
        bitsPerChannel: Int?
    ) {
        self.formatID = formatID
        self.formatFlags = formatFlags
        self.fourCC = fourCC
        self.bitsPerChannel = bitsPerChannel
    }

    public var displayName: String {
        switch formatID {
        case kAudioFormatMPEGLayer3:
            return "MP3"
        case kAudioFormatMPEG4AAC:
            return "AAC"
        case kAudioFormatAppleLossless:
            return "ALAC"
        case kAudioFormatFLAC:
            return "FLAC"
        case kAudioFormatLinearPCM:
            let representation = (formatFlags & kAudioFormatFlagIsFloat) != 0
                ? "Float PCM"
                : "PCM"
            return bitsPerChannel.map { "\($0)-bit \(representation)" } ?? representation
        default:
            let readable = fourCC.unicodeScalars.filter {
                $0.value >= 0x21 && $0.value <= 0x7E && $0 != "[" && $0 != "]"
            }
            return readable.isEmpty ? "Unknown audio" : String(String.UnicodeScalarView(readable))
        }
    }
}

public struct AudioStreamDescriptor: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    public let validFrameCount: Int64?
    public let presentationStartSeconds: Double
    public let durationSeconds: Double
    public let hasTimelineDiscontinuities: Bool
    public let channelLayout: AudioChannelLayoutDescriptor
    public let codec: AudioCodecDescriptor
    public let estimatedBitRate: Int?

    public init(
        sampleRate: Int,
        channelCount: Int,
        validFrameCount: Int64?,
        presentationStartSeconds: Double,
        durationSeconds: Double,
        hasTimelineDiscontinuities: Bool = false,
        channelLayout: AudioChannelLayoutDescriptor,
        codec: AudioCodecDescriptor,
        estimatedBitRate: Int?
    ) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.validFrameCount = validFrameCount
        self.presentationStartSeconds = presentationStartSeconds
        self.durationSeconds = durationSeconds
        self.hasTimelineDiscontinuities = hasTimelineDiscontinuities
        self.channelLayout = channelLayout
        self.codec = codec
        self.estimatedBitRate = estimatedBitRate
    }

    public var audioFileInfo: AudioFileInfo {
        AudioFileInfo(
            sampleRate: sampleRate,
            channelCount: channelCount,
            frameCount: Int(validFrameCount ?? Int64((durationSeconds * Double(sampleRate)).rounded()))
        )
    }
}

public struct MediaStream: Sendable, Equatable {
    public let streamIndex: Int
    public let mediaType: String
    public let codecName: String?
    public let isEnabled: Bool
    public let languageCode: String?
    public let title: String?
    public let dispositions: [String]
    public let startSeconds: Double
    public let durationSeconds: Double

    public init(
        streamIndex: Int,
        mediaType: String,
        codecName: String? = nil,
        isEnabled: Bool,
        languageCode: String?,
        title: String? = nil,
        dispositions: [String] = [],
        startSeconds: Double,
        durationSeconds: Double
    ) {
        self.streamIndex = streamIndex
        self.mediaType = mediaType
        self.codecName = codecName
        self.isEnabled = isEnabled
        self.languageCode = languageCode
        self.title = title
        self.dispositions = dispositions.sorted()
        self.startSeconds = startSeconds
        self.durationSeconds = durationSeconds
    }

    public var isAudio: Bool { mediaType == "soun" }
    public var isUserFacing: Bool {
        mediaType == "soun" || mediaType == "vide" || mediaType == "sbtl"
            || dispositions.contains("attached_pic")
    }
}

public enum MediaAudioTrackAvailability: Sendable, Equatable {
    case selectable(AudioStreamDescriptor)
    case unavailable(reason: String)

    public var audioDescriptor: AudioStreamDescriptor? {
        guard case .selectable(let descriptor) = self else { return nil }
        return descriptor
    }

    public var unavailableReason: String? {
        guard case .unavailable(let reason) = self else { return nil }
        return reason
    }
}

public struct MediaAudioTrackOption: Sendable, Equatable, Identifiable {
    public let streamIndex: Int
    public let ordinal: Int
    public let title: String?
    public let languageCode: String?
    public let isEnabled: Bool
    public let isMainProgramContent: Bool
    public let availability: MediaAudioTrackAvailability

    public var id: Int { streamIndex }
    public var isSelectable: Bool { availability.audioDescriptor != nil }
    public var audioDescriptor: AudioStreamDescriptor? { availability.audioDescriptor }
    public var unavailableReason: String? { availability.unavailableReason }

    public init(
        streamIndex: Int,
        ordinal: Int,
        title: String? = nil,
        languageCode: String? = nil,
        isEnabled: Bool,
        isMainProgramContent: Bool = false,
        availability: MediaAudioTrackAvailability
    ) {
        self.streamIndex = streamIndex
        self.ordinal = ordinal
        self.title = title
        self.languageCode = languageCode
        self.isEnabled = isEnabled
        self.isMainProgramContent = isMainProgramContent
        self.availability = availability
    }
}

public struct MediaAssetInspection: Sendable, Equatable {
    public let container: MediaContainer
    public let durationSeconds: Double
    public let tracks: [MediaStream]
    public let audioTracks: [MediaAudioTrackOption]
    public let suggestedAudioStreamIndex: Int
    public let metadataItemCount: Int

    public init(
        container: MediaContainer,
        durationSeconds: Double,
        tracks: [MediaStream],
        audioTracks: [MediaAudioTrackOption],
        metadataItemCount: Int
    ) throws {
        let audioTrackIDs = Set(tracks.lazy.filter(\.isAudio).map(\.streamIndex))
        let optionTrackIDs = Set(audioTracks.map(\.streamIndex))
        guard !audioTracks.isEmpty,
              optionTrackIDs.count == audioTracks.count,
              optionTrackIDs == audioTrackIDs else {
            throw MediaIOError.invalidAudioFormat("audio-track inventory does not match media tracks")
        }
        guard let suggested = Self.suggestedTrack(in: audioTracks) else {
            throw MediaIOError.noSelectableAudioTrack
        }
        self.container = container
        self.durationSeconds = durationSeconds
        self.tracks = tracks
        self.audioTracks = audioTracks
        self.suggestedAudioStreamIndex = suggested.streamIndex
        self.metadataItemCount = metadataItemCount
    }

    public func mediaInfo(selectingAudioStreamIndex streamIndex: Int) throws -> MediaFileInfo {
        guard let option = audioTracks.first(where: { $0.streamIndex == streamIndex }),
              let descriptor = option.audioDescriptor else {
            throw MediaIOError.invalidAudioStreamSelection(streamIndex)
        }
        return MediaFileInfo(
            container: container,
            durationSeconds: durationSeconds,
            tracks: tracks,
            selectedAudioStreamIndex: streamIndex,
            selectedAudio: descriptor,
            metadataItemCount: metadataItemCount
        )
    }

    private static func suggestedTrack(
        in tracks: [MediaAudioTrackOption]
    ) -> MediaAudioTrackOption? {
        tracks.first { $0.isSelectable && $0.isEnabled && $0.isMainProgramContent }
            ?? tracks.first { $0.isSelectable && $0.isEnabled }
            ?? tracks.first { $0.isSelectable }
    }
}

public struct MediaFileInfo: Sendable, Equatable {
    public let container: MediaContainer
    public let durationSeconds: Double
    public let tracks: [MediaStream]
    public let selectedAudioStreamIndex: Int
    public let selectedAudio: AudioStreamDescriptor
    public let metadataItemCount: Int
    public let isProtectedContent: Bool

    public init(
        container: MediaContainer,
        durationSeconds: Double,
        tracks: [MediaStream],
        selectedAudioStreamIndex: Int,
        selectedAudio: AudioStreamDescriptor,
        metadataItemCount: Int,
        isProtectedContent: Bool = false
    ) {
        self.container = container
        self.durationSeconds = durationSeconds
        self.tracks = tracks
        self.selectedAudioStreamIndex = selectedAudioStreamIndex
        self.selectedAudio = selectedAudio
        self.metadataItemCount = metadataItemCount
        self.isProtectedContent = isProtectedContent
    }

    public var isVideo: Bool { container.isVideoContainer }
    public var audioTrackCount: Int { tracks.lazy.filter(\.isAudio).count }

    package func settingSelectedAudioValidFrameCount(_ frameCount: Int64) -> MediaFileInfo {
        let audio = selectedAudio
        return MediaFileInfo(
            container: container,
            durationSeconds: durationSeconds,
            tracks: tracks,
            selectedAudioStreamIndex: selectedAudioStreamIndex,
            selectedAudio: AudioStreamDescriptor(
                sampleRate: audio.sampleRate,
                channelCount: audio.channelCount,
                validFrameCount: frameCount,
                presentationStartSeconds: audio.presentationStartSeconds,
                durationSeconds: Double(frameCount) / Double(audio.sampleRate),
                hasTimelineDiscontinuities: audio.hasTimelineDiscontinuities,
                channelLayout: audio.channelLayout,
                codec: audio.codec,
                estimatedBitRate: audio.estimatedBitRate
            ),
            metadataItemCount: metadataItemCount,
            isProtectedContent: isProtectedContent
        )
    }
}

public struct TimedPlanarAudioBlock: Sendable, Equatable {
    public let audio: PlanarAudioBlock
    public let presentationFrame: Int64
    public let startsDiscontinuity: Bool

    public init(
        audio: PlanarAudioBlock,
        presentationFrame: Int64,
        startsDiscontinuity: Bool = false
    ) {
        self.audio = audio
        self.presentationFrame = presentationFrame
        self.startsDiscontinuity = startsDiscontinuity
    }
}

public enum MediaIOError: Error, LocalizedError, Sendable, Equatable {
    case unsupportedContainer(String)
    case unreadable(String)
    case protectedContent
    case missingAudioTrack
    case noSelectableAudioTrack
    case invalidAudioStreamSelection(Int)
    case invalidAudioFormat(String)
    case unsupportedChannelLayout(Int)
    case outputContainerMismatch(expected: String, actual: String)
    case readerFailed(String)
    case writerFailed(String)
    case ffmpegUnavailable(String)
    case ffmpegFailed(String)

    public var errorDescription: String? {
        switch self {
        case .unsupportedContainer(let value): return "Unsupported media container: \(value)"
        case .unreadable(let value): return "Media file is not readable: \(value)"
        case .protectedContent: return "Protected media cannot be enhanced."
        case .missingAudioTrack: return "The selected media file has no audio track."
        case .noSelectableAudioTrack:
            return "The selected media file has no supported audio track."
        case .invalidAudioStreamSelection(let index):
            return "Audio stream \(index) is not available for enhancement."
        case .invalidAudioFormat(let value): return "Invalid audio format: \(value)"
        case .unsupportedChannelLayout(let count):
            return "A \(count)-channel input requires explicit channel-layout metadata."
        case let .outputContainerMismatch(expected, actual):
            return "Output must use .\(expected), not .\(actual)."
        case .readerFailed(let value): return "Media decoding failed: \(value)"
        case .writerFailed(let value): return "Media encoding failed: \(value)"
        case .ffmpegUnavailable(let value):
            return "Bundled FFmpeg is unavailable: \(value)"
        case .ffmpegFailed(let value):
            return "FFmpeg media handling failed: \(value)"
        }
    }
}
