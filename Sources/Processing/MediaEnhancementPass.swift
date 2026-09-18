// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Foundation
import Inference
import MediaIO

struct MediaEnhancementPassResult {
    let decodedFrames: Int64
    let enhancedFrames: Int64
    let previewAssets: MediaPreviewAssets?
    let finalizingStart: ContinuousClock.Instant
    let channelEnhancementPasses: [Duration]
}

/// Runs only the bounded native-rate channel pass; transaction policy stays in
/// `MediaFileEnhancementPipeline`.
struct MediaEnhancementPass {
    let enhancer: any StreamingSpeechEnhancer

    func run(
        source: any NativeRateAudioSource,
        sink: any NativeRateAudioSink,
        audio: AudioStreamDescriptor,
        validation: DecodedInputValidation,
        previewCapture: MediaPreviewCapture?,
        settings: InferenceSettings,
        totalWork: Int64,
        clock: MediaProcessingClock,
        channelClock: MediaProcessingClock,
        progress: @escaping @Sendable (MediaProcessingProgress) -> Void
    ) async throws -> MediaEnhancementPassResult {
        var sessions = try await makeSessions(
            count: audio.channelCount,
            sampleRate: audio.sampleRate,
            settings: settings
        )
        let blockSize = try Self.commonBlockSize(sessions)
        var completedWork: Int64 = 0
        var enhancedFrames: Int64 = 0
        var decodedFrames: Int64 = 0
        var segmentOutputFrame: Int64?
        var channelEnhancementPasses = Array(
            repeating: Duration.zero,
            count: audio.channelCount
        )

        while let inputBlock = try source.read(maxFrameCount: blockSize) {
            try Task.checkCancellation()
            guard inputBlock.audio.channelCount == audio.channelCount else {
                throw MediaProcessingError.invalidInputLayout(
                    "channel count changed while reading"
                )
            }
            decodedFrames += Int64(inputBlock.audio.frameCount)
            try previewCapture?.appendOriginal(inputBlock)
            if inputBlock.startsDiscontinuity {
                try await finishSegment(
                    sessions: sessions,
                    sink: sink,
                    outputFrame: &segmentOutputFrame,
                    enhancedFrames: &enhancedFrames,
                    previewCapture: previewCapture,
                    channelEnhancementPasses: &channelEnhancementPasses,
                    clock: channelClock
                )
                sessions = try await makeSessions(
                    count: audio.channelCount,
                    sampleRate: audio.sampleRate,
                    settings: settings
                )
                _ = try Self.commonBlockSize(sessions, expected: blockSize)
                segmentOutputFrame = inputBlock.presentationFrame
            } else if segmentOutputFrame == nil {
                segmentOutputFrame = inputBlock.presentationFrame
            }

            var outputChannels = [[Float]]()
            outputChannels.reserveCapacity(audio.channelCount)
            for channel in 0..<audio.channelCount {
                try Task.checkCancellation()
                outputChannels.append(
                    try await timedAppend(
                        session: sessions[channel],
                        input: inputBlock.audio.channels[channel],
                        clock: channelClock,
                        elapsed: &channelEnhancementPasses[channel]
                    )
                )
                completedWork += Int64(inputBlock.audio.frameCount)
                progress(.init(
                    phase: .enhancing,
                    completedWork: min(completedWork, totalWork),
                    totalWork: totalWork
                ))
            }
            try await appendAligned(
                outputChannels,
                sink: sink,
                outputFrame: &segmentOutputFrame,
                enhancedFrames: &enhancedFrames,
                previewCapture: previewCapture
            )
        }
        let finalizingStart = clock.now()
        source.close()
        try validation.validate(actualFrameCount: decodedFrames)
        progress(.init(
            phase: .finalizing,
            completedWork: totalWork,
            totalWork: totalWork
        ))
        try await finishSegment(
            sessions: sessions,
            sink: sink,
            outputFrame: &segmentOutputFrame,
            enhancedFrames: &enhancedFrames,
            previewCapture: previewCapture,
            channelEnhancementPasses: &channelEnhancementPasses,
            clock: channelClock
        )
        try await sink.close()
        guard sink.writtenFrameCount == enhancedFrames else {
            throw MediaProcessingError.outputIdentityChanged(
                "replacement sink accepted \(sink.writtenFrameCount) of "
                    + "\(enhancedFrames) enhanced frames"
            )
        }
        return MediaEnhancementPassResult(
            decodedFrames: decodedFrames,
            enhancedFrames: enhancedFrames,
            previewAssets: try previewCapture?.finalize(),
            finalizingStart: finalizingStart,
            channelEnhancementPasses: channelEnhancementPasses
        )
    }

    private func makeSessions(
        count: Int,
        sampleRate: Int,
        settings: InferenceSettings
    ) async throws -> [any SpeechEnhancementSession] {
        var result = [any SpeechEnhancementSession]()
        result.reserveCapacity(count)
        for _ in 0..<count {
            result.append(try await enhancer.makeSession(
                sampleRate: sampleRate,
                settings: settings
            ))
        }
        return result
    }

    private func finishSegment(
        sessions: [any SpeechEnhancementSession],
        sink: any NativeRateAudioSink,
        outputFrame: inout Int64?,
        enhancedFrames: inout Int64,
        previewCapture: MediaPreviewCapture?,
        channelEnhancementPasses: inout [Duration],
        clock: MediaProcessingClock
    ) async throws {
        var channels = [[Float]]()
        channels.reserveCapacity(sessions.count)
        for channel in sessions.indices {
            try Task.checkCancellation()
            let start = clock.now()
            channels.append(try await sessions[channel].finish())
            channelEnhancementPasses[channel] += start.duration(to: clock.now())
        }
        try await appendAligned(
            channels,
            sink: sink,
            outputFrame: &outputFrame,
            enhancedFrames: &enhancedFrames,
            previewCapture: previewCapture
        )
    }

    private func timedAppend(
        session: any SpeechEnhancementSession,
        input: [Float],
        clock: MediaProcessingClock,
        elapsed: inout Duration
    ) async throws -> [Float] {
        let start = clock.now()
        let output = try await session.append(input)
        elapsed += start.duration(to: clock.now())
        return output
    }

    private func appendAligned(
        _ channels: [[Float]],
        sink: any NativeRateAudioSink,
        outputFrame: inout Int64?,
        enhancedFrames: inout Int64,
        previewCapture: MediaPreviewCapture?
    ) async throws {
        guard let count = channels.first?.count,
              channels.allSatisfy({ $0.count == count }) else {
            throw MediaProcessingError.inconsistentChannelOutput
        }
        guard count > 0 else { return }
        guard let presentationFrame = outputFrame else {
            throw MediaProcessingError.inconsistentChannelOutput
        }
        let block = TimedPlanarAudioBlock(
            audio: try PlanarAudioBlock(channels: channels),
            presentationFrame: presentationFrame
        )
        try await sink.append(block)
        try previewCapture?.appendEnhanced(block)
        outputFrame = presentationFrame + Int64(count)
        enhancedFrames += Int64(count)
    }

    private static func commonBlockSize(
        _ sessions: [any SpeechEnhancementSession],
        expected: Int? = nil
    ) throws -> Int {
        guard let size = sessions.first?.recommendedInputFrameCount,
              size > 0,
              sessions.allSatisfy({ $0.recommendedInputFrameCount == size }),
              expected.map({ $0 == size }) ?? true else {
            throw MediaProcessingError.inconsistentSessionBlockSize
        }
        return size
    }
}
