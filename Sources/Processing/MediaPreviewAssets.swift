// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Foundation
import MediaIO

public struct MediaPreviewAssets: Sendable, Equatable {
    public let inputAudioURL: URL
    public let outputAudioURL: URL
    public let originalWaveformLevels: [Double]
    public let enhancedWaveformLevels: [Double]

    private let workspace: MediaPreviewWorkspace

    init(
        workspace: MediaPreviewWorkspace,
        originalWaveformLevels: [Double],
        enhancedWaveformLevels: [Double]
    ) {
        self.workspace = workspace
        inputAudioURL = workspace.inputAudioURL
        outputAudioURL = workspace.outputAudioURL
        self.originalWaveformLevels = originalWaveformLevels
        self.enhancedWaveformLevels = enhancedWaveformLevels
    }

    public static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.inputAudioURL == rhs.inputAudioURL
            && lhs.outputAudioURL == rhs.outputAudioURL
            && lhs.originalWaveformLevels == rhs.originalWaveformLevels
            && lhs.enhancedWaveformLevels == rhs.enhancedWaveformLevels
    }
}

final class MediaPreviewWorkspace: Sendable {
    let rootURL: URL
    let inputAudioURL: URL
    let outputAudioURL: URL

    init() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "speechlens-media-preview-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: root,
            withIntermediateDirectories: false,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        rootURL = root
        inputAudioURL = root.appendingPathComponent("original.wav")
        outputAudioURL = root.appendingPathComponent("enhanced.wav")
    }

    deinit { try? FileManager.default.removeItem(at: rootURL) }
}

/// Actor-local owner for mutable preview capture state. This intentionally does
/// not conform to Sendable; one processing transaction performs every mutation.
final class MediaPreviewCapture {
    let workspace: MediaPreviewWorkspace

    private var originalWriter: AudioFileStreamWriter?
    private var enhancedWriter: AudioFileStreamWriter?
    private var originalFrameCount: Int64 = 0
    private var enhancedFrameCount: Int64 = 0
    private var originalWaveform: WaveformEnvelopeAccumulator
    private var enhancedWaveform: WaveformEnvelopeAccumulator

    static func shouldCreate(
        policy: MediaPreviewPolicy
    ) -> Bool {
        policy == .retainAudioAndWaveforms
    }

    init(
        audio: AudioStreamDescriptor,
        timelineFrames: Int64,
        outputContainer: MediaContainer = .wav
    ) throws {
        _ = outputContainer
        let workspace = try MediaPreviewWorkspace()
        self.workspace = workspace
        originalWriter = try AudioFileStreamWriter(
            url: workspace.inputAudioURL,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount
        )
        enhancedWriter = try AudioFileStreamWriter(
            url: workspace.outputAudioURL,
            sampleRate: audio.sampleRate,
            channelCount: audio.channelCount
        )
        originalWaveform = WaveformEnvelopeAccumulator(timelineFrames: timelineFrames)
        enhancedWaveform = WaveformEnvelopeAccumulator(timelineFrames: timelineFrames)
    }

    deinit {
        try? originalWriter?.close()
        try? enhancedWriter?.close()
    }

    func appendOriginal(_ block: TimedPlanarAudioBlock) throws {
        guard let originalWriter else {
            throw AudioIOError.writeFailed("Preview capture is finalized")
        }
        try originalWriter.append(block.audio)
        originalFrameCount += Int64(block.audio.frameCount)
        originalWaveform.append(block)
    }

    func appendEnhanced(_ block: TimedPlanarAudioBlock) throws {
        guard let enhancedWriter else {
            throw AudioIOError.writeFailed("Preview capture is finalized")
        }
        try enhancedWriter.append(block.audio)
        enhancedFrameCount += Int64(block.audio.frameCount)
        enhancedWaveform.append(block)
    }

    func finalize() throws -> MediaPreviewAssets {
        guard let originalWriter else {
            throw AudioIOError.writeFailed("Preview capture is already finalized")
        }
        if originalFrameCount != enhancedFrameCount {
            throw AudioIOError.writeFailed(
                "Captured previews contain different frame counts: "
                    + "\(originalFrameCount)/\(enhancedFrameCount)"
            )
        }
        try originalWriter.close()
        self.originalWriter = nil
        try enhancedWriter?.close()
        enhancedWriter = nil
        return MediaPreviewAssets(
            workspace: workspace,
            originalWaveformLevels: originalWaveform.levels(),
            enhancedWaveformLevels: enhancedWaveform.levels()
        )
    }
}

struct WaveformEnvelopeAccumulator {
    private let binCount: Int
    private let timelineFrames: Int64
    private var peaks: [Float]

    init(timelineFrames: Int64, binCount: Int = 96) {
        self.binCount = max(1, binCount)
        self.timelineFrames = max(1, timelineFrames)
        peaks = [Float](repeating: 0, count: max(1, binCount))
    }

    mutating func append(_ block: TimedPlanarAudioBlock) {
        let channelScale = 1 / Float(block.audio.channelCount)
        for frame in 0..<block.audio.frameCount {
            var mixed: Float = 0
            for channel in block.audio.channels { mixed += channel[frame] }
            let position = max(0, block.presentationFrame + Int64(frame))
            let bin = min(binCount - 1, Int(position * Int64(binCount) / timelineFrames))
            peaks[bin] = max(peaks[bin], abs(mixed * channelScale))
        }
    }

    func levels() -> [Double] {
        let maximum = peaks.max() ?? 0
        guard maximum > 0 else { return Array(repeating: 0.08, count: binCount) }
        return peaks.map { max(0.08, pow(Double($0 / maximum), 0.7)) }
    }
}
