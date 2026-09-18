// SPDX-License-Identifier: Apache-2.0

import Foundation

public struct MediaWaveformEnvelope: Sendable {
    public init() {}

    /// Produces a fixed-size display envelope through a bounded scan of the
    /// deterministically selected audio track.
    public func levels(
        from url: URL,
        selectingAudioStreamIndex selectedAudioStreamIndex: Int,
        binCount: Int = 96
    ) async throws -> [Double] {
        guard binCount > 0 else { return [] }
        let engine = UnifiedFFmpegMediaEngine()
        let inspection = try await engine.inspect(url)
        let info = try inspection.media.mediaInfo(
            selectingAudioStreamIndex: selectedAudioStreamIndex
        )
        let source = try await engine.makeAudioSource(request: UnifiedAudioSourceRequest(
            url: url, info: info, context: inspection.context
        ))
        defer { source.close() }
        let descriptor = info.selectedAudio
        let startFrame = Int64(
            (descriptor.presentationStartSeconds * Double(descriptor.sampleRate)).rounded()
        )
        let timelineFrames = max(
            Int64(1),
            descriptor.validFrameCount
                ?? Int64((descriptor.durationSeconds * Double(descriptor.sampleRate)).rounded())
        )
        var peaks = [Float](repeating: 0, count: binCount)
        while let block = try source.read(maxFrameCount: 8_192) {
            try Task.checkCancellation()
            let scale = 1 / Float(block.audio.channelCount)
            for frame in 0..<block.audio.frameCount {
                var mixed: Float = 0
                for channel in block.audio.channels { mixed += channel[frame] }
                let relative = max(0, block.presentationFrame + Int64(frame) - startFrame)
                let bin = min(binCount - 1, Int(relative * Int64(binCount) / timelineFrames))
                peaks[bin] = max(peaks[bin], abs(mixed * scale))
            }
        }
        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return Array(repeating: 0.08, count: binCount) }
        return peaks.map { max(0.08, pow(Double($0 / maximum), 0.7)) }
    }
}
