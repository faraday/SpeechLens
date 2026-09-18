// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
@testable import MediaIO

enum MediaIOTestHarness {
    static func temporaryDirectory(prefix: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: false
        )
        return url
    }

    static func captureSelectedAudio(
        _ url: URL,
        maxFrameCount: Int
    ) async throws -> MediaAudioCapture {
        let engine = UnifiedFFmpegMediaEngine(
            executableURL: MediaTestRuntime.ffmpegURL,
            probeExecutableURL: MediaTestRuntime.ffprobeURL
        )
        let inspection = try await engine.inspect(url)
        let info = try inspection.media.mediaInfo(
            selectingAudioStreamIndex: inspection.media.suggestedAudioStreamIndex
        )
        let source = try await engine.makeAudioSource(
            request: UnifiedAudioSourceRequest(
                url: url,
                info: info,
                context: inspection.context
            )
        )
        defer { source.close() }

        var channels = Array(
            repeating: [Float](),
            count: info.selectedAudio.channelCount
        )
        var blocks = [MediaAudioBlockCapture]()
        while let block = try source.read(maxFrameCount: maxFrameCount) {
            blocks.append(MediaAudioBlockCapture(
                presentationFrame: block.presentationFrame,
                frameCount: block.audio.frameCount
            ))
            for channel in channels.indices {
                channels[channel].append(
                    contentsOf: block.audio.channels[channel]
                )
            }
        }
        let repeatedEOF = try source.read(maxFrameCount: maxFrameCount) == nil
            && source.read(maxFrameCount: 1) == nil
        source.close()
        source.close()
        let postCloseEOF = try source.read(maxFrameCount: maxFrameCount) == nil
        return MediaAudioCapture(
            sampleRate: info.selectedAudio.sampleRate,
            channelCount: info.selectedAudio.channelCount,
            channels: channels,
            blocks: blocks,
            repeatedEOF: repeatedEOF,
            postCloseEOF: postCloseEOF
        )
    }

}

struct MediaAudioCapture {
    let sampleRate: Int
    let channelCount: Int
    let channels: [[Float]]
    let blocks: [MediaAudioBlockCapture]
    let repeatedEOF: Bool
    let postCloseEOF: Bool

    var frameCount: Int { channels.first?.count ?? 0 }
    var firstPresentationFrame: Int64? { blocks.first?.presentationFrame }
    var largestBlock: Int { blocks.map(\.frameCount).max() ?? 0 }
    var isContiguousFromZero: Bool {
        var expected: Int64 = 0
        for block in blocks {
            guard block.presentationFrame == expected else { return false }
            expected += Int64(block.frameCount)
        }
        return expected == Int64(frameCount)
    }

    func rootMeanSquare(frames: Range<Int>, channel: Int) -> Double? {
        guard channel >= 0,
              channel < channels.count,
              frames.lowerBound >= 0,
              frames.upperBound <= frameCount,
              !frames.isEmpty else {
            return nil
        }
        let samples = channels[channel][frames]
        let power = samples.reduce(0.0) {
            $0 + Double($1) * Double($1)
        }
        return sqrt(power / Double(samples.count))
    }
}

struct MediaAudioBlockCapture {
    let presentationFrame: Int64
    let frameCount: Int
}
