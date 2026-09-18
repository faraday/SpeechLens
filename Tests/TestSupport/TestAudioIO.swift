// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Foundation

/// Test-only whole-file audio value. Production code must use bounded streaming APIs.
public struct TestAudioContents: Sendable, Equatable {
    public let samples: [Float]
    public let sampleRate: Int
    public let channelCount: Int

    public var frameCount: Int {
        guard channelCount > 0 else { return 0 }
        return samples.count / channelCount
    }

    public init(samples: [Float], sampleRate: Int, channelCount: Int) {
        self.samples = samples
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }

    public init(planarChannels channels: [[Float]], sampleRate: Int) throws {
        guard sampleRate > 0 else {
            throw AudioIOError.invalidBuffer("sampleRate must be greater than zero")
        }
        guard let frameCount = channels.first?.count else {
            throw AudioIOError.invalidBuffer("at least one channel is required")
        }
        guard channels.allSatisfy({ $0.count == frameCount }) else {
            throw AudioIOError.invalidBuffer("all channels must have the same frame count")
        }

        var interleaved = [Float]()
        interleaved.reserveCapacity(frameCount * channels.count)
        for frame in 0..<frameCount {
            for channel in channels {
                interleaved.append(channel[frame])
            }
        }
        self.init(samples: interleaved, sampleRate: sampleRate, channelCount: channels.count)
    }

    public func planarChannels() throws -> [[Float]] {
        guard channelCount > 0 else {
            throw AudioIOError.invalidBuffer("channelCount must be greater than zero")
        }
        guard samples.count.isMultiple(of: channelCount) else {
            throw AudioIOError.invalidBuffer(
                "interleaved sample count must be divisible by channelCount"
            )
        }

        var channels = Array(
            repeating: [Float](repeating: 0, count: frameCount),
            count: channelCount
        )
        for frame in 0..<frameCount {
            let base = frame * channelCount
            for channel in 0..<channelCount {
                channels[channel][frame] = samples[base + channel]
            }
        }
        return channels
    }

    public func downmixedToMonoSamples() -> [Float] {
        guard channelCount > 0 else { return [] }
        guard channelCount > 1 else { return samples }
        guard frameCount > 0 else { return [] }

        var mono = [Float](repeating: 0, count: frameCount)
        let scale = 1 / Float(channelCount)
        for frame in 0..<frameCount {
            let base = frame * channelCount
            var sum: Float = 0
            for channel in 0..<channelCount {
                sum += samples[base + channel]
            }
            mono[frame] = sum * scale
        }
        return mono
    }
}

public struct TestAudioFileReader: Sendable {
    public init() {}

    public func read(from url: URL) async throws -> TestAudioContents {
        try readSync(from: url)
    }

    public func readSync(from url: URL) throws -> TestAudioContents {
        let reader = try AudioFileStreamReader(url: url)
        defer { reader.close() }

        var interleaved = [Float]()
        interleaved.reserveCapacity(reader.info.frameCount * reader.info.channelCount)
        while let block = try reader.read(maxFrameCount: 8192) {
            for frame in 0..<block.frameCount {
                for channel in block.channels {
                    interleaved.append(channel[frame])
                }
            }
        }
        return TestAudioContents(
            samples: interleaved,
            sampleRate: reader.info.sampleRate,
            channelCount: reader.info.channelCount
        )
    }
}

public struct TestAudioFileWriter: Sendable {
    public init() {}

    public func write(_ contents: TestAudioContents, to url: URL) async throws {
        try writeSync(contents, to: url)
    }

    public func writeSync(_ contents: TestAudioContents, to url: URL) throws {
        let writer = try AudioFileStreamWriter(
            url: url,
            sampleRate: contents.sampleRate,
            channelCount: contents.channelCount
        )
        do {
            let channels = try contents.planarChannels()
            var offset = 0
            while offset < contents.frameCount {
                let end = min(contents.frameCount, offset + 8192)
                try writer.append(PlanarAudioBlock(
                    channels: channels.map { Array($0[offset..<end]) }
                ))
                offset = end
            }
            try writer.close()
        } catch {
            try? writer.close()
            throw error
        }
    }
}
