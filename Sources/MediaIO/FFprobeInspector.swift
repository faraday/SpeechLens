// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation

/// Executes FFprobe and tolerantly decodes its raw JSON document. It contains
/// no output-recipe policy.
struct FFprobeClient: Sendable {
    let executableURL: URL

    func document(_ url: URL) async throws -> ProbeDocument {
        let data = try await FFmpegCommandRunner(executableURL: executableURL)
            .captureStandardOutput([
                "-v", "error", "-of", "json",
                "-show_entries", Self.selectedEntries, url.path,
            ])
        do {
            return try JSONDecoder().decode(ProbeDocument.self, from: data)
        } catch {
            throw MediaIOError.ffmpegFailed(
                "ffprobe returned invalid JSON: \(error.localizedDescription)"
            )
        }
    }

    private static let selectedEntries = [
        "format=format_name,duration", "format_tags",
        "stream=index,id,codec_name,codec_long_name,codec_type,codec_tag_string,profile,sample_rate,channels",
        "stream=ch_layout,channel_layout,bits_per_sample,bits_per_raw_sample,start_time,duration,duration_ts,time_base,nb_frames,bit_rate",
        "stream_tags", "stream_disposition=default,forced,attached_pic",
    ].joined(separator: ":")
}

/// Mechanical conversion from a raw probe document to public media values.
/// The recipe planner validates output policy after this conversion.
enum FFprobeMapping {
    typealias AudioDescriptor = (ProbeStream, Double) throws -> AudioStreamDescriptor

    static func requireFormatName(
        _ document: ProbeDocument,
        expected: [String]
    ) throws {
        let names = document.format?.formatName?.split(separator: ",").map(String.init)
        guard let names, expected.contains(where: names.contains) else {
            throw MediaIOError.invalidAudioFormat(
                "ffprobe detected \(document.format?.formatName ?? "an unknown container"), "
                    + "expected \(expected.joined(separator: ", "))"
            )
        }
    }

    static func inspection(
        from document: ProbeDocument,
        container: MediaContainer,
        additionalMetadataCount: Int = 0,
        metadataItemFloor: Int = 0,
        audioDescriptor: AudioDescriptor
    ) throws -> MediaAssetInspection {
        guard !document.streams.isEmpty else { throw MediaIOError.missingAudioTrack }
        let duration = document.format?.duration?.finiteValue
            ?? document.streams.compactMap(\.durationSeconds).max() ?? 0
        var tracks = [MediaStream]()
        var audioOptions = [MediaAudioTrackOption]()
        var audioOrdinal = 0
        for stream in try sortedStreams(document.streams) {
            let streamDuration = stream.durationSeconds ?? duration
            tracks.append(trackDescriptor(
                stream, duration: streamDuration
            ))
            guard stream.codecType == "audio" else { continue }
            audioOrdinal += 1
            let availability: MediaAudioTrackAvailability
            do {
                availability = .selectable(try audioDescriptor(stream, streamDuration))
            } catch {
                availability = .unavailable(reason: error.localizedDescription)
            }
            audioOptions.append(MediaAudioTrackOption(
                streamIndex: stream.index,
                ordinal: audioOrdinal,
                title: stream.tags?["title"]
                    ?? stream.tags?["handler_name"]
                    ?? stream.codecLongName,
                languageCode: stream.tags?["language"],
                isEnabled: true,
                isMainProgramContent: stream.disposition?["default"] == 1,
                availability: availability
            ))
        }
        guard !audioOptions.isEmpty else { throw MediaIOError.missingAudioTrack }
        let probedMetadata = (document.format?.tags?.count ?? 0)
            + document.streams.reduce(0) { $0 + ($1.tags?.count ?? 0) }
            + additionalMetadataCount
        return try MediaAssetInspection(
            container: container,
            durationSeconds: duration,
            tracks: tracks,
            audioTracks: audioOptions,
            metadataItemCount: max(probedMetadata, metadataItemFloor)
        )
    }

    static func audioDescriptor(
        _ stream: ProbeStream,
        duration: Double,
        validFrameCount: Int64? = nil,
        exactDuration: Double? = nil,
        presentationSampleRate: Int? = nil,
        presentationChannelCount: Int? = nil
    ) throws -> AudioStreamDescriptor {
        guard let sampleRate = presentationSampleRate
                ?? stream.sampleRate?.intValue,
              sampleRate > 0,
              let channelCount = presentationChannelCount
                ?? stream.channels?.intValue
                ?? stream.channelLayout?.channelCount?.intValue,
              channelCount > 0 else {
            throw MediaIOError.invalidAudioFormat(
                "ffprobe did not report sample rate and channels"
            )
        }
        let name = stream.channelLayout?.name ?? stream.legacyChannelLayout
        // PCM frame counts describe decoded samples exactly. Prefer that
        // timeline over AVI's packet-rounded stream duration. Compressed
        // `nb_frames` values count encoded/container units and must never be
        // interpreted as decoded PCM samples.
        let pcmFrameDuration = stream.codecName?.hasPrefix("pcm_") == true
            ? stream.frameCount.flatMap { frameCount in
                Double(frameCount.value) / Double(sampleRate)
            }
            : nil
        let decodedDuration = exactDuration
            ?? pcmFrameDuration
            ?? stream.durationSeconds
            ?? duration
        return AudioStreamDescriptor(
            sampleRate: sampleRate,
            channelCount: channelCount,
            validFrameCount: validFrameCount,
            presentationStartSeconds: 0,
            durationSeconds: decodedDuration,
            hasTimelineDiscontinuities: false,
            channelLayout: try channelLayout(name: name, channelCount: channelCount),
            codec: codecDescriptor(stream),
            estimatedBitRate: stream.bitRate?.intValue
        )
    }

    static func sampleRateAndChannelCount(
        _ stream: ProbeStream
    ) throws -> (sampleRate: Int, channelCount: Int) {
        guard let sampleRate = stream.sampleRate?.intValue, sampleRate > 0,
              let channelCount = stream.channels?.intValue
                ?? stream.channelLayout?.channelCount?.intValue,
              channelCount > 0 else {
            throw MediaIOError.invalidAudioFormat(
                "ffprobe did not report sample rate and channels"
            )
        }
        return (sampleRate, channelCount)
    }

    private static func sortedStreams(_ streams: [ProbeStream]) throws -> [ProbeStream] {
        for stream in streams {
            guard stream.index >= 0, stream.index < Int(Int32.max) else {
                throw MediaIOError.invalidAudioFormat("invalid ffprobe stream index")
            }
        }
        return streams.sorted { $0.index < $1.index }
    }

    private static func trackDescriptor(
        _ stream: ProbeStream,
        duration: Double
    ) -> MediaStream {
        MediaStream(
            streamIndex: stream.index,
            mediaType: stream.mediaType,
            codecName: stream.codecName,
            isEnabled: true,
            languageCode: stream.tags?["language"],
            title: stream.tags?["title"] ?? stream.tags?["handler_name"],
            dispositions: (stream.disposition ?? [:])
                .filter { $0.value == 1 }
                .map(\.key),
            startSeconds: stream.startTime?.finiteValue ?? 0,
            durationSeconds: duration
        )
    }

    private static func codecDescriptor(_ stream: ProbeStream) -> AudioCodecDescriptor {
        let name = stream.codecName ?? "unknown"
        let isPCM = name.hasPrefix("pcm_")
        var flags: UInt32 = 0
        if isPCM {
            flags = kAudioFormatFlagIsPacked
            if name.hasPrefix("pcm_f") { flags |= kAudioFormatFlagIsFloat }
            else if name.hasPrefix("pcm_s") { flags |= kAudioFormatFlagIsSignedInteger }
            if name.hasSuffix("be") { flags |= kAudioFormatFlagIsBigEndian }
        }
        let formatID: AudioFormatID = switch name {
        case "mp3": kAudioFormatMPEGLayer3
        case "aac": kAudioFormatMPEG4AAC
        case "alac": kAudioFormatAppleLossless
        case "flac": kAudioFormatFLAC
        default: isPCM ? kAudioFormatLinearPCM : 0
        }
        let depth = stream.bitsPerRawSample?.intValue ?? stream.bitsPerSample?.intValue
        return AudioCodecDescriptor(
            formatID: formatID,
            formatFlags: flags,
            fourCC: stream.codecTag ?? name,
            bitsPerChannel: depth.flatMap { $0 > 0 ? $0 : nil }
        )
    }

    private static func channelLayout(
        name: String?,
        channelCount: Int
    ) throws -> AudioChannelLayoutDescriptor {
        let canonical = channelCount == 1
            ? "mono"
            : (channelCount == 2 ? "stereo" : name?.lowercased())
        if channelCount <= 2 {
            return AudioChannelLayoutDescriptor(
                rawData: nil,
                inferred: true,
                ffmpegName: canonical
            )
        }
        let tag: AudioChannelLayoutTag? = switch canonical {
        case "2.1": kAudioChannelLayoutTag_ITU_2_1
        case "3.0": kAudioChannelLayoutTag_MPEG_3_0_A
        case "quad": kAudioChannelLayoutTag_Quadraphonic
        case "4.0": kAudioChannelLayoutTag_MPEG_4_0_A
        case "5.0": kAudioChannelLayoutTag_MPEG_5_0_A
        case "5.1", "5.1(side)": kAudioChannelLayoutTag_MPEG_5_1_A
        case "6.1": kAudioChannelLayoutTag_MPEG_6_1_A
        case "7.1", "7.1(wide)": kAudioChannelLayoutTag_MPEG_7_1_A
        default: nil
        }
        guard let tag, canonical != nil else {
            return AudioChannelLayoutDescriptor(
                rawData: nil,
                inferred: true,
                ffmpegName: canonical ?? "\(channelCount)c"
            )
        }
        var data = Data(count: MemoryLayout<AudioChannelLayout>.size)
        data.withUnsafeMutableBytes { bytes in
            guard let baseAddress = bytes.baseAddress else { return }
            let value = baseAddress.assumingMemoryBound(to: AudioChannelLayout.self)
            value.pointee.mChannelLayoutTag = tag
            value.pointee.mChannelBitmap = AudioChannelBitmap()
            value.pointee.mNumberChannelDescriptions = 0
        }
        return AudioChannelLayoutDescriptor(
            rawData: data,
            inferred: false,
            ffmpegName: canonical
        )
    }
}

struct ProbeDocument: Decodable {
    let streams: [ProbeStream]
    let format: ProbeFormat?
}

struct ProbeFormat: Decodable {
    let formatName: String?
    let duration: ProbeDecimal?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case formatName = "format_name", duration, tags
    }
}

struct ProbeChannelLayout: Decodable {
    let channelCount: ProbeInteger?
    let name: String?

    enum CodingKeys: String, CodingKey {
        case channelCount = "nb_channels"
        case name = "layout"
    }
}

struct ProbeStream: Decodable {
    let index: Int
    let trackID: ProbeTrackIdentifier?
    let codecName: String?
    let codecLongName: String?
    let profile: String?
    let codecType: String?
    let codecTag: String?
    let sampleRate: ProbeInteger?
    let channels: ProbeInteger?
    let channelLayout: ProbeChannelLayout?
    let legacyChannelLayout: String?
    let bitsPerSample: ProbeInteger?
    let bitsPerRawSample: ProbeInteger?
    let startTime: ProbeDecimal?
    let duration: ProbeDecimal?
    let durationTimestamp: ProbeInteger?
    let timeBase: String?
    let frameCount: ProbeInteger?
    let bitRate: ProbeInteger?
    let disposition: [String: Int]?
    let tags: [String: String]?

    enum CodingKeys: String, CodingKey {
        case index
        case trackID = "id"
        case codecName = "codec_name"
        case codecLongName = "codec_long_name"
        case profile
        case codecType = "codec_type"
        case codecTag = "codec_tag_string"
        case sampleRate = "sample_rate"
        case channels
        case channelLayout = "ch_layout"
        case legacyChannelLayout = "channel_layout"
        case bitsPerSample = "bits_per_sample"
        case bitsPerRawSample = "bits_per_raw_sample"
        case startTime = "start_time"
        case duration
        case durationTimestamp = "duration_ts"
        case timeBase = "time_base"
        case frameCount = "nb_frames"
        case bitRate = "bit_rate"
        case disposition
        case tags
    }

    var mediaType: String {
        switch codecType {
        case "audio": "soun"
        case "video": "vide"
        case "subtitle": "sbtl"
        case "data": "meta"
        case "attachment": "attm"
        default: codecType ?? "unknown"
        }
    }

    var durationSeconds: Double? {
        duration?.finiteValue
            ?? durationTimestamp.flatMap { ticks in
                timeBase.fractionValue.map { Double(ticks.value) * $0 }
            }
    }
}

struct ProbeTrackIdentifier: Decodable {
    let value: Int32

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int32.self) {
            value = integer
            return
        }
        let string = try container.decode(String.self)
        let parsed: UInt64?
        if string.lowercased().hasPrefix("0x") {
            parsed = UInt64(string.dropFirst(2), radix: 16)
        } else {
            parsed = UInt64(string)
        }
        guard let parsed, parsed > 0, parsed <= UInt64(Int32.max) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected a positive container track ID"
            )
        }
        value = Int32(parsed)
    }
}

struct ProbeInteger: Decodable {
    let value: Int64
    var intValue: Int? { Int(exactly: value) }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let integer = try? container.decode(Int64.self) {
            value = integer
            return
        }
        let string = try container.decode(String.self)
        guard let integer = Int64(string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected integer"
            )
        }
        value = integer
    }
}

struct ProbeDecimal: Decodable {
    let value: Double
    var finiteValue: Double? { value.isFinite ? value : nil }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let number = try? container.decode(Double.self) {
            value = number
            return
        }
        let string = try container.decode(String.self)
        guard let number = Double(string) else {
            throw DecodingError.dataCorruptedError(
                in: container, debugDescription: "expected decimal"
            )
        }
        value = number
    }
}

extension Optional where Wrapped == String {
    var fractionValue: Double? {
        guard let value = self else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let numerator = Double(parts[0]),
              let denominator = Double(parts[1]),
              denominator != 0 else { return nil }
        return numerator / denominator
    }

    var rational: (Int64, Int64)? {
        guard let value = self else { return nil }
        let parts = value.split(separator: "/", maxSplits: 1)
        guard parts.count == 2,
              let numerator = Int64(parts[0]),
              let denominator = Int64(parts[1]),
              denominator != 0 else { return nil }
        return (numerator, denominator)
    }
}
