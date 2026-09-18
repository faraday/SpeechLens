// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Darwin
import Foundation

final class UnifiedFFmpegOutputSink: NativeRateAudioSink {
    private static let writeChunk = 64 * 1_024

    private let process: Process
    private let inputPipe: Pipe
    private let diagnostic: BoundedProcessDiagnosticTail
    private let outputURL: URL
    private let channelCount: Int
    private var expectedFrame: Int64?
    private var closed = false

    private(set) var writtenFrameCount: Int64 = 0
    init(
        executableURL: URL,
        outputURL: URL,
        sourceURL: URL,
        source: AudioStreamDescriptor,
        execution: UnifiedFFmpegExecutionPlan
    ) throws {
        self.outputURL = outputURL
        channelCount = source.channelCount
        let pipe = Pipe()
        inputPipe = pipe
        let diagnostic = BoundedProcessDiagnosticTail()
        self.diagnostic = diagnostic

        let routing = execution.routing
        let retained = routing.retainedTracks
        let replacementOutputIndex = routing.selectedOutputStreamIndex

        var arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            // Keep the helper's queue and thread footprint bounded while inference
            // supplies PCM at a slower, serial rate.
            "-threads", "1",
            "-i", sourceURL.path,
            "-f", "f32le",
            "-ar", String(source.sampleRate),
            "-ch_layout", source.channelLayout.ffmpegName
                ?? (source.channelCount == 1 ? "mono"
                    : (source.channelCount == 2 ? "stereo" : "\(source.channelCount)c")),
            "-i", "pipe:0",
        ]
        for track in retained {
            arguments += [
                "-map",
                track.streamIndex == routing.selectedInputStreamIndex
                    ? "1:a:0"
                    : "0:\(track.streamIndex)",
            ]
        }
        for (outputIndex, track) in retained.enumerated() {
            arguments += [
                "-map_metadata:s:\(outputIndex)", "0:s:\(track.streamIndex)",
                "-disposition:\(outputIndex)",
                track.dispositions.isEmpty ? "0" : track.dispositions.joined(separator: "+"),
            ]
        }
        // Match the preflight's bounded interleave policy for the real encode.
        arguments += [
            "-map_metadata", "0",
            "-map_chapters", "0",
            "-c", "copy",
            "-c:\(replacementOutputIndex)", execution.encoder.ffmpegName,
        ]
        arguments += execution.encoder.ffmpegArguments(
            plannedBitRate: execution.plannedBitRate
        )
        if execution.outputPlan.outputContainer == .mp4
            || execution.outputPlan.outputContainer == .mov
            || execution.outputPlan.outputContainer == .m4a {
            arguments += ["-movflags", "+faststart"]
        }
        arguments += [
            "-max_interleave_delta", "1000000",
            "-max_muxing_queue_size", "1024",
            "-muxing_queue_data_threshold", "16777216",
            "-f", execution.outputPlan.outputContainer.ffmpegMuxerName,
            outputURL.path,
        ]

        let process = Process()
        self.process = process
        process.executableURL = executableURL
        process.arguments = arguments
        process.qualityOfService = .utility
        process.standardInput = pipe
        process.standardOutput = FileHandle.nullDevice
        process.standardError = diagnostic.writer
        do {
            try process.run()
        } catch {
            diagnostic.close()
            throw MediaIOError.ffmpegUnavailable(error.localizedDescription)
        }
        pipe.fileHandleForReading.closeFile()
        diagnostic.closeParentWriter()
        let descriptor = pipe.fileHandleForWriting.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0,
              fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0,
              fcntl(descriptor, F_SETNOSIGPIPE, 1) == 0 else {
            cancel()
            throw MediaIOError.writerFailed("unable to configure FFmpeg input pipe")
        }
    }

    deinit {
        if !closed { cancel() }
    }

    nonisolated(nonsending)
    func append(_ block: TimedPlanarAudioBlock) async throws {
        guard !closed, block.audio.channelCount == channelCount else {
            throw MediaIOError.writerFailed("invalid block for unified FFmpeg output")
        }
        if let expectedFrame, block.presentationFrame != expectedFrame {
            throw MediaIOError.writerFailed("enhanced PCM timeline is not continuous")
        }
        var interleaved = [Float](
            repeating: 0,
            count: block.audio.frameCount * channelCount
        )
        for frame in 0..<block.audio.frameCount {
            for channel in 0..<channelCount {
                interleaved[frame * channelCount + channel] =
                    block.audio.channels[channel][frame]
            }
        }
        try interleaved.withUnsafeBytes { try writeAll($0) }
        writtenFrameCount += Int64(block.audio.frameCount)
        expectedFrame = block.presentationFrame + Int64(block.audio.frameCount)
    }

    nonisolated(nonsending)
    func close() async throws {
        guard !closed else { return }
        closed = true
        try? inputPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(120)
        while process.isRunning {
            if Task.isCancelled {
                stop()
                throw CancellationError()
            }
            if Date() >= deadline {
                stop()
                diagnostic.close()
                try? FileManager.default.removeItem(at: outputURL)
                throw MediaIOError.writerFailed(
                    "FFmpeg did not finish the bounded output transaction"
                )
            }
            usleep(10_000)
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let message = diagnostic.message()
            diagnostic.close()
            try? FileManager.default.removeItem(at: outputURL)
            throw MediaIOError.writerFailed(
                message.isEmpty
                    ? "FFmpeg exited with status \(process.terminationStatus)"
                    : message
            )
        }
        diagnostic.close()
        guard let size = try? outputURL.resourceValues(forKeys: [.fileSizeKey]).fileSize,
              size > 0 else {
            throw MediaIOError.writerFailed("FFmpeg produced no output")
        }
    }

    func cancel() {
        guard !closed else { return }
        closed = true
        try? inputPipe.fileHandleForWriting.close()
        stop()
        diagnostic.close()
        try? FileManager.default.removeItem(at: outputURL)
    }

    private func writeAll(_ bytes: UnsafeRawBufferPointer) throws {
        guard let base = bytes.baseAddress else { return }
        let descriptor = inputPipe.fileHandleForWriting.fileDescriptor
        var offset = 0
        while offset < bytes.count {
            if Task.isCancelled { throw CancellationError() }
            var value = pollfd(fd: descriptor, events: Int16(POLLOUT | POLLHUP | POLLERR), revents: 0)
            let status = Darwin.poll(&value, 1, 100)
            if status == 0 { continue }
            if status < 0, errno == EINTR { continue }
            guard status > 0, (value.revents & Int16(POLLOUT)) != 0 else {
                throw MediaIOError.writerFailed(
                    diagnostic.message().isEmpty
                        ? "FFmpeg closed its PCM input"
                        : diagnostic.message()
                )
            }
            let count = min(Self.writeChunk, bytes.count - offset)
            let result = Darwin.write(descriptor, base.advanced(by: offset), count)
            if result > 0 { offset += result }
            else if result < 0, errno == EAGAIN || errno == EINTR { continue }
            else { throw MediaIOError.writerFailed("FFmpeg rejected enhanced PCM") }
        }
    }

    private func stop() {
        guard process.isRunning else { return }
        process.terminate()
        for _ in 0..<50 where process.isRunning { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

}
