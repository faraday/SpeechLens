// SPDX-License-Identifier: Apache-2.0

import AVFoundation
import AudioIO
import AudioToolbox
import Foundation

package struct AACDecodedPresentation: Sendable, Equatable {
    let sampleRate: Int
    let channelCount: Int
    let durationSeconds: Double
}

package protocol AACPCMDecoder: Sendable {
    func probe(
        sourceURL: URL,
        trackID: Int32
    ) async throws -> AACDecodedPresentation

    func open(
        sourceURL: URL,
        trackID: Int32,
        descriptor: AudioStreamDescriptor
    ) async throws -> any NativeRateAudioSource
}

package struct AppleAACPCMDecoder: AACPCMDecoder {
    package init() {}

    package func probe(
        sourceURL: URL,
        trackID: Int32
    ) async throws -> AACDecodedPresentation {
        do {
            let session = try await AppleAACReaderSession(
                sourceURL: sourceURL,
                trackID: trackID
            )
            defer { session.cancel() }
            let sample = try session.requireNextSample()
            let shape = try Self.pcmShape(sample)
            return AACDecodedPresentation(
                sampleRate: shape.sampleRate,
                channelCount: shape.channelCount,
                durationSeconds: session.timeRange.duration.seconds
            )
        } catch {
            throw Self.decodeError(error)
        }
    }

    package func open(
        sourceURL: URL,
        trackID: Int32,
        descriptor: AudioStreamDescriptor
    ) async throws -> any NativeRateAudioSource {
        do {
            let session = try await AppleAACReaderSession(
                sourceURL: sourceURL,
                trackID: trackID
            )
            return try AppleAACAudioSource(
                session: session,
                descriptor: descriptor
            )
        } catch {
            throw Self.decodeError(error)
        }
    }

    static func pcmShape(
        _ sample: CMSampleBuffer
    ) throws -> (sampleRate: Int, channelCount: Int) {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              stream.pointee.mFormatID == kAudioFormatLinearPCM else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox did not expose decoded linear PCM"
            )
        }
        let sampleRate = Int(stream.pointee.mSampleRate.rounded())
        let channelCount = Int(stream.pointee.mChannelsPerFrame)
        guard sampleRate > 0, channelCount > 0 else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox reported an invalid AAC presentation format"
            )
        }
        return (sampleRate, channelCount)
    }

    static func interleavedSamples(
        _ sample: CMSampleBuffer,
        channelCount: Int
    ) throws -> [Float] {
        let frameCount = CMSampleBufferGetNumSamples(sample)
        guard frameCount > 0 else { return [] }
        let multiplication = frameCount.multipliedReportingOverflow(
            by: channelCount
        )
        let valueCount = multiplication.partialValue
        guard !multiplication.overflow, valueCount > 0 else {
            throw MediaIOError.readerFailed("Apple AAC sample size overflow")
        }
        var list = AudioBufferList(
            mNumberBuffers: 1,
            mBuffers: AudioBuffer(
                mNumberChannels: UInt32(channelCount),
                mDataByteSize: 0,
                mData: nil
            )
        )
        var retainedBlock: CMBlockBuffer?
        // The retained block owns `mData` until `Array` copies the PCM below.
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sample,
            bufferListSizeNeededOut: nil,
            bufferListOut: &list,
            bufferListSize: MemoryLayout<AudioBufferList>.size,
            blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault,
            flags: 0,
            blockBufferOut: &retainedBlock
        )
        guard status == noErr,
              list.mNumberBuffers == 1,
              Int(list.mBuffers.mNumberChannels) == channelCount,
              let data = list.mBuffers.mData,
              Int(list.mBuffers.mDataByteSize)
                >= valueCount * MemoryLayout<Float>.size else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox returned an invalid AAC PCM buffer"
            )
        }
        return Array(UnsafeBufferPointer(
            start: data.assumingMemoryBound(to: Float.self),
            count: valueCount
        ))
    }

    private static func decodeError(_ error: Error) -> MediaIOError {
        if let mediaError = error as? MediaIOError { return mediaError }
        return .readerFailed(
            "Apple AudioToolbox could not decode the selected AAC track: "
                + error.localizedDescription
        )
    }
}

private final class AppleAACReaderSession {
    let reader: AVAssetReader
    let output: AVAssetReaderTrackOutput
    let timeRange: CMTimeRange

    init(sourceURL: URL, trackID: Int32) async throws {
        let asset = AVURLAsset(url: sourceURL)
        let tracks = try await asset.loadTracks(withMediaType: .audio)
        guard let track = tracks.first(where: { $0.trackID == trackID }) else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox could not find AAC container track \(trackID)"
            )
        }
        let timeRange = try await track.load(.timeRange)
        guard timeRange.isValid, timeRange.duration.isNumeric else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox reported an invalid AAC timeline"
            )
        }
        let reader = try AVAssetReader(asset: asset)
        let output = AVAssetReaderTrackOutput(
            track: track,
            outputSettings: [
                AVFormatIDKey: Int(kAudioFormatLinearPCM),
                AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true,
                AVLinearPCMIsBigEndianKey: false,
                AVLinearPCMIsNonInterleaved: false,
            ]
        )
        output.alwaysCopiesSampleData = false
        guard reader.canAdd(output) else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox rejected the selected AAC track"
            )
        }
        reader.add(output)
        guard reader.startReading() else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox could not start AAC decoding: "
                    + (reader.error?.localizedDescription ?? "unknown codec error")
            )
        }
        self.reader = reader
        self.output = output
        self.timeRange = timeRange
    }

    func requireNextSample() throws -> CMSampleBuffer {
        if let sample = output.copyNextSampleBuffer() { return sample }
        throw terminalError(emptyMessage: "Apple AAC decoder produced no PCM")
    }

    func terminalError(emptyMessage: String) -> MediaIOError {
        if reader.status == .failed {
            return .readerFailed(
                "Apple AudioToolbox AAC decoding failed: "
                    + (reader.error?.localizedDescription ?? "unknown codec error")
            )
        }
        return .readerFailed(emptyMessage)
    }

    func cancel() {
        if reader.status == .reading { reader.cancelReading() }
    }
}

private final class AppleAACAudioSource: NativeRateAudioSource {
    let descriptor: AudioStreamDescriptor

    private let session: AppleAACReaderSession
    private var pendingInterleaved = [Float]()
    private var pendingFrameOffset = 0
    private var pendingPresentationFrame: Int64 = 0
    private var silenceFrames: Int64 = 0
    private var nextFrame: Int64 = 0
    private var timelineOrigin: CMTime?
    private let timelineFrameLimit: Int64
    private var reachedEOF = false
    private var closed = false

    init(
        session: AppleAACReaderSession,
        descriptor: AudioStreamDescriptor
    ) throws {
        self.session = session
        self.descriptor = descriptor
        timelineFrameLimit = Int64(
            (descriptor.durationSeconds * Double(descriptor.sampleRate)).rounded()
        )
        guard timelineFrameLimit > 0 else {
            throw MediaIOError.readerFailed(
                "Apple AudioToolbox reported an empty AAC presentation timeline"
            )
        }
    }

    deinit { close() }

    func read(maxFrameCount: Int) throws -> TimedPlanarAudioBlock? {
        guard !closed else { return nil }
        guard !Task.isCancelled else {
            close()
            throw CancellationError()
        }
        guard maxFrameCount > 0 else {
            throw MediaIOError.readerFailed("maxFrameCount must be positive")
        }
        if nextFrame >= timelineFrameLimit {
            reachedEOF = true
            session.cancel()
            return nil
        }
        while silenceFrames == 0 && pendingFrameCount == 0 && !reachedEOF {
            try loadNextSample()
        }
        if silenceFrames > 0 {
            let count = min(
                Int64(maxFrameCount),
                silenceFrames,
                timelineFrameLimit - nextFrame
            )
            let channels = Array(
                repeating: [Float](repeating: 0, count: Int(count)),
                count: descriptor.channelCount
            )
            let block = TimedPlanarAudioBlock(
                audio: try PlanarAudioBlock(channels: channels),
                presentationFrame: nextFrame
            )
            silenceFrames -= count
            nextFrame += count
            return block
        }
        guard pendingFrameCount > 0 else {
            if reachedEOF { return nil }
            throw MediaIOError.readerFailed("Apple AAC decoder stalled")
        }
        let count = min(
            maxFrameCount,
            pendingFrameCount,
            Int(timelineFrameLimit - nextFrame)
        )
        var channels = Array(
            repeating: [Float](repeating: 0, count: count),
            count: descriptor.channelCount
        )
        for frame in 0..<count {
            let base = (pendingFrameOffset + frame) * descriptor.channelCount
            for channel in 0..<descriptor.channelCount {
                channels[channel][frame] = pendingInterleaved[base + channel]
            }
        }
        let block = TimedPlanarAudioBlock(
            audio: try PlanarAudioBlock(channels: channels),
            presentationFrame: pendingPresentationFrame + Int64(pendingFrameOffset)
        )
        pendingFrameOffset += count
        nextFrame += Int64(count)
        if pendingFrameCount == 0 {
            pendingInterleaved.removeAll(keepingCapacity: true)
            pendingFrameOffset = 0
        }
        return block
    }

    func close() {
        guard !closed else { return }
        closed = true
        session.cancel()
        pendingInterleaved.removeAll()
    }

    private var pendingFrameCount: Int {
        pendingInterleaved.count / descriptor.channelCount - pendingFrameOffset
    }

    private func loadNextSample() throws {
        guard let sample = session.output.copyNextSampleBuffer() else {
            if session.reader.status == .failed {
                throw session.terminalError(emptyMessage: "Apple AAC decoding failed")
            }
            reachedEOF = true
            return
        }
        let shape = try AppleAACPCMDecoder.pcmShape(sample)
        guard shape.sampleRate == descriptor.sampleRate,
              shape.channelCount == descriptor.channelCount else {
            throw MediaIOError.readerFailed(
                "Apple AAC presentation format changed after preflight"
            )
        }
        let timestamp = CMSampleBufferGetPresentationTimeStamp(sample)
        guard timestamp.isNumeric else {
            throw MediaIOError.readerFailed(
                "Apple AAC decoder returned an invalid presentation timestamp"
            )
        }
        if timelineOrigin == nil { timelineOrigin = timestamp }
        let relative = CMTimeSubtract(timestamp, timelineOrigin ?? timestamp)
        var targetFrame = CMTimeConvertScale(
            relative,
            timescale: CMTimeScale(descriptor.sampleRate),
            method: .roundHalfAwayFromZero
        ).value
        targetFrame = max(0, targetFrame)
        var samples = try AppleAACPCMDecoder.interleavedSamples(
            sample,
            channelCount: descriptor.channelCount
        )
        let frameCount = samples.count / descriptor.channelCount
        if targetFrame < nextFrame {
            let overlap = min(Int(nextFrame - targetFrame), frameCount)
            samples.removeFirst(overlap * descriptor.channelCount)
            targetFrame += Int64(overlap)
        }
        guard !samples.isEmpty else { return }
        if targetFrame >= timelineFrameLimit {
            reachedEOF = true
            session.cancel()
            return
        }
        let retainedFrames = min(
            samples.count / descriptor.channelCount,
            Int(timelineFrameLimit - targetFrame)
        )
        if retainedFrames * descriptor.channelCount < samples.count {
            samples.removeLast(
                samples.count - retainedFrames * descriptor.channelCount
            )
        }
        if targetFrame > nextFrame {
            silenceFrames = targetFrame - nextFrame
        }
        pendingInterleaved = samples
        pendingFrameOffset = 0
        pendingPresentationFrame = targetFrame
    }
}
