// SPDX-License-Identifier: Apache-2.0

// ExtAudioFile is used without format conversion or resampling.

import Foundation
import AudioToolbox

/// Sequential native-rate planar reader backed by ExtAudioFile.
public final class AudioFileStreamReader {
    public let info: AudioFileInfo

    private var audioFile: ExtAudioFileRef?

    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioIOError.fileNotFound(url.path)
        }

        var openedFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &openedFile)
        guard status == noErr, let openedFile else {
            throw AudioIOError.readFailed(
                "ExtAudioFileOpenURL failed with status \(status) for \(url.lastPathComponent)"
            )
        }

        do {
            var fileFormat = AudioStreamBasicDescription()
            var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
            status = ExtAudioFileGetProperty(
                openedFile,
                kExtAudioFileProperty_FileDataFormat,
                &propertySize,
                &fileFormat
            )
            guard status == noErr else {
                throw AudioIOError.readFailed("Failed to read file format: status \(status)")
            }

            let sampleRate = Int(fileFormat.mSampleRate)
            let channelCount = Int(fileFormat.mChannelsPerFrame)
            guard sampleRate > 0 else {
                throw AudioIOError.readFailed("Invalid sample rate \(fileFormat.mSampleRate)")
            }
            guard channelCount > 0 else {
                throw AudioIOError.readFailed("Invalid channel count \(fileFormat.mChannelsPerFrame)")
            }

            var frameCount: Int64 = 0
            propertySize = UInt32(MemoryLayout<Int64>.size)
            status = ExtAudioFileGetProperty(
                openedFile,
                kExtAudioFileProperty_FileLengthFrames,
                &propertySize,
                &frameCount
            )
            guard status == noErr, frameCount >= 0, frameCount <= Int64(Int.max) else {
                throw AudioIOError.readFailed("Failed to read a representable frame count: status \(status)")
            }

            var clientFormat = Self.planarClientFormat(
                sampleRate: fileFormat.mSampleRate,
                channelCount: channelCount
            )
            status = ExtAudioFileSetProperty(
                openedFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            )
            guard status == noErr else {
                throw AudioIOError.readFailed("Failed to set planar client format: status \(status)")
            }

            self.info = AudioFileInfo(
                sampleRate: sampleRate,
                channelCount: channelCount,
                frameCount: Int(frameCount)
            )
            self.audioFile = openedFile
        } catch {
            ExtAudioFileDispose(openedFile)
            throw error
        }
    }

    deinit { close() }

    public func read(maxFrameCount: Int) throws -> PlanarAudioBlock? {
        guard maxFrameCount > 0 else {
            throw AudioIOError.invalidBuffer("maxFrameCount must be greater than zero")
        }
        guard let audioFile else {
            throw AudioIOError.readFailed("Reader is closed")
        }
        guard maxFrameCount <= Int(UInt32.max) / MemoryLayout<Float>.size else {
            throw AudioIOError.invalidBuffer("maxFrameCount is too large")
        }

        let pointers = (0..<info.channelCount).map { _ in
            UnsafeMutablePointer<Float>.allocate(capacity: maxFrameCount)
        }
        defer { pointers.forEach { $0.deallocate() } }

        let bufferList = AudioBufferList.allocate(maximumBuffers: info.channelCount)
        defer { free(bufferList.unsafeMutablePointer) }
        bufferList.count = info.channelCount
        for channel in 0..<info.channelCount {
            bufferList[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(maxFrameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointers[channel])
            )
        }

        var frames = UInt32(maxFrameCount)
        let status = ExtAudioFileRead(audioFile, &frames, bufferList.unsafeMutablePointer)
        guard status == noErr else {
            throw AudioIOError.readFailed("ExtAudioFileRead failed with status \(status)")
        }
        guard frames > 0 else { return nil }

        let frameCount = Int(frames)
        let channels = pointers.map {
            Array(UnsafeBufferPointer(start: $0, count: frameCount))
        }
        return try PlanarAudioBlock(channels: channels)
    }

    public func close() {
        guard let audioFile else { return }
        self.audioFile = nil
        ExtAudioFileDispose(audioFile)
    }

    fileprivate static func planarClientFormat(
        sampleRate: Float64,
        channelCount: Int
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat
                | kAudioFormatFlagIsPacked
                | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: UInt32(MemoryLayout<Float>.size),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(MemoryLayout<Float>.size),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(MemoryLayout<Float>.size * 8),
            mReserved: 0
        )
    }
}

// MARK: - AudioFileInfoReader

public struct AudioFileInfo: Sendable, Equatable {
    public let sampleRate: Int
    public let channelCount: Int
    public let frameCount: Int

    public var durationSeconds: Double {
        guard sampleRate > 0 else { return 0 }
        return Double(frameCount) / Double(sampleRate)
    }

    public init(sampleRate: Int, channelCount: Int, frameCount: Int) {
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.frameCount = frameCount
    }
}

/// Reads container metadata only. No samples are decoded and no sample rate conversion occurs.
public struct AudioFileInfoReader: Sendable {
    public init() {}

    public func readInfo(from url: URL) throws -> AudioFileInfo {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioIOError.fileNotFound(url.path)
        }

        var extAudioFile: ExtAudioFileRef?
        var status = ExtAudioFileOpenURL(url as CFURL, &extAudioFile)
        guard status == noErr, let audioFile = extAudioFile else {
            throw AudioIOError.readFailed(
                "ExtAudioFileOpenURL failed with status \(status) for \(url.lastPathComponent)")
        }
        defer { ExtAudioFileDispose(audioFile) }

        var fileFormat = AudioStreamBasicDescription()
        var propertySize = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        status = ExtAudioFileGetProperty(
            audioFile,
            kExtAudioFileProperty_FileDataFormat,
            &propertySize,
            &fileFormat
        )
        guard status == noErr else {
            throw AudioIOError.readFailed("Failed to read file format: status \(status)")
        }

        var frameCount: Int64 = 0
        propertySize = UInt32(MemoryLayout<Int64>.size)
        status = ExtAudioFileGetProperty(
            audioFile,
            kExtAudioFileProperty_FileLengthFrames,
            &propertySize,
            &frameCount
        )
        guard status == noErr, frameCount >= 0 else {
            throw AudioIOError.readFailed("Failed to read frame count: status \(status)")
        }

        return AudioFileInfo(
            sampleRate: Int(fileFormat.mSampleRate),
            channelCount: Int(fileFormat.mChannelsPerFrame),
            frameCount: Int(frameCount)
        )
    }
}

/// Incremental native-rate planar writer backed by ExtAudioFile.
public final class AudioFileStreamWriter {
    public let sampleRate: Int
    public let channelCount: Int
    public private(set) var framesWritten = 0

    private var audioFile: ExtAudioFileRef?

    public init(url: URL, sampleRate: Int, channelCount: Int) throws {
        guard sampleRate > 0 else {
            throw AudioIOError.writeFailed("Invalid sample rate: \(sampleRate)")
        }
        guard channelCount > 0 else {
            throw AudioIOError.writeFailed("Invalid channel count: \(channelCount)")
        }

        let isAIFF = ["aif", "aiff"].contains(url.pathExtension.lowercased())
        let fileBytesPerSample = isAIFF ? 2 : MemoryLayout<Float>.size
        let fileFlags: UInt32 = isAIFF
            ? (kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsBigEndian | kAudioFormatFlagIsPacked)
            : (kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked)
        var fileFormat = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate),
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: fileFlags,
            mBytesPerPacket: UInt32(fileBytesPerSample * channelCount),
            mFramesPerPacket: 1,
            mBytesPerFrame: UInt32(fileBytesPerSample * channelCount),
            mChannelsPerFrame: UInt32(channelCount),
            mBitsPerChannel: UInt32(fileBytesPerSample * 8),
            mReserved: 0
        )

        var createdFile: ExtAudioFileRef?
        var status = ExtAudioFileCreateWithURL(
            url as CFURL,
            Self.audioFileType(for: url),
            &fileFormat,
            nil,
            AudioFileFlags.eraseFile.rawValue,
            &createdFile
        )
        guard status == noErr, let createdFile else {
            throw AudioIOError.writeFailed(
                "ExtAudioFileCreateWithURL failed with status \(status)"
            )
        }

        do {
            var clientFormat = AudioFileStreamReader.planarClientFormat(
                sampleRate: Float64(sampleRate),
                channelCount: channelCount
            )
            status = ExtAudioFileSetProperty(
                createdFile,
                kExtAudioFileProperty_ClientDataFormat,
                UInt32(MemoryLayout<AudioStreamBasicDescription>.size),
                &clientFormat
            )
            guard status == noErr else {
                throw AudioIOError.writeFailed("Failed to set planar client format: status \(status)")
            }
            self.sampleRate = sampleRate
            self.channelCount = channelCount
            self.audioFile = createdFile
        } catch {
            ExtAudioFileDispose(createdFile)
            throw error
        }
    }

    deinit { try? close() }

    public func append(_ block: PlanarAudioBlock) throws {
        guard let audioFile else {
            throw AudioIOError.writeFailed("Writer is closed")
        }
        guard block.channelCount == channelCount else {
            throw AudioIOError.invalidBuffer(
                "Expected \(channelCount) channels, received \(block.channelCount)"
            )
        }
        guard block.frameCount <= Int(UInt32.max) / MemoryLayout<Float>.size else {
            throw AudioIOError.invalidBuffer("Audio block is too large")
        }

        let pointers = block.channels.map { channel -> UnsafeMutablePointer<Float> in
            let pointer = UnsafeMutablePointer<Float>.allocate(capacity: channel.count)
            pointer.initialize(from: channel, count: channel.count)
            return pointer
        }
        defer {
            for pointer in pointers {
                pointer.deinitialize(count: block.frameCount)
                pointer.deallocate()
            }
        }

        let bufferList = AudioBufferList.allocate(maximumBuffers: channelCount)
        defer { free(bufferList.unsafeMutablePointer) }
        bufferList.count = channelCount
        for channel in 0..<channelCount {
            bufferList[channel] = AudioBuffer(
                mNumberChannels: 1,
                mDataByteSize: UInt32(block.frameCount * MemoryLayout<Float>.size),
                mData: UnsafeMutableRawPointer(pointers[channel])
            )
        }

        let status = ExtAudioFileWrite(
            audioFile,
            UInt32(block.frameCount),
            bufferList.unsafeMutablePointer
        )
        guard status == noErr else {
            throw AudioIOError.writeFailed(
                "ExtAudioFileWrite failed at frame \(framesWritten): status \(status)"
            )
        }
        framesWritten += block.frameCount
    }

    public func close() throws {
        guard let audioFile else { return }
        self.audioFile = nil
        let status = ExtAudioFileDispose(audioFile)
        guard status == noErr else {
            throw AudioIOError.writeFailed("ExtAudioFileDispose failed with status \(status)")
        }
    }

    private static func audioFileType(for url: URL) -> AudioFileTypeID {
        switch url.pathExtension.lowercased() {
        case "wav", "wave":
            return kAudioFileWAVEType
        case "aif", "aiff":
            return kAudioFileAIFFType
        case "aifc":
            return kAudioFileAIFCType
        case "caf":
            return kAudioFileCAFType
        default:
            return kAudioFileWAVEType
        }
    }
}

// MARK: - AudioFormatDetector

/// Detects audio file format from file header.
public struct AudioFormatDetector: Sendable {
    public static func detect(url: URL) throws -> AudioFormat {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw AudioIOError.fileNotFound(url.path)
        }

        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw AudioIOError.readFailed("Cannot open file: \(error.localizedDescription)")
        }
        defer { handle.closeFile() }

        guard let headerData = try? handle.read(upToCount: 12), headerData.count >= 4 else {
            throw AudioIOError.readFailed("File too small to detect format")
        }

        let magic4 = String(data: headerData[0..<4], encoding: .ascii) ?? ""

        if magic4 == "RIFF", headerData.count >= 12 {
            let riffType = String(data: headerData[8..<12], encoding: .ascii) ?? ""
            if riffType == "WAVE" {
                return .wav
            }
        }

        if magic4 == "FORM", headerData.count >= 12 {
            let formType = String(data: headerData[8..<12], encoding: .ascii) ?? ""
            if formType == "AIFF" || formType == "AIFC" {
                return .aiff
            }
        }

        if magic4 == "caff" {
            return .caf
        }

        return .unknown(url.pathExtension)
    }
}
