// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Darwin
import Foundation

final class FFmpegPipeAudioSource: NativeRateAudioSource {
    let descriptor: AudioStreamDescriptor

    private static let pipeReadSize = 64 * 1_024
    private let process: Process
    private let outputPipe: Pipe
    private let diagnostic: BoundedProcessDiagnosticTail
    private var pendingBytes = Data()
    private var nextFrame: Int64 = 0
    private var reachedCleanEOF = false
    private var closed = false

    init(
        executableURL: URL,
        sourceURL: URL,
        streamIndex: Int,
        descriptor: AudioStreamDescriptor
    ) throws {
        guard streamIndex >= 0, descriptor.sampleRate > 0, descriptor.channelCount > 0 else {
            throw MediaIOError.invalidAudioFormat("invalid FFmpeg stream configuration")
        }
        self.descriptor = descriptor

        let outputPipe = Pipe()
        self.outputPipe = outputPipe
        let diagnostic = BoundedProcessDiagnosticTail()
        self.diagnostic = diagnostic

        let process = Process()
        self.process = process
        process.executableURL = executableURL
        process.arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-threads", "1",
            "-i", sourceURL.path,
            "-map", "0:\(streamIndex)",
            "-vn", "-sn", "-dn",
            // `async` is used only for hard timestamp reconciliation. Explicitly
            // disable soft compensation so decoded PCM is never time-stretched.
            "-af", "aresample=async=1:first_pts=0:min_hard_comp=0:max_soft_comp=0",
            "-c:a", "pcm_f32le",
            "-f", "f32le",
            "-blocksize", String(Self.pipeReadSize),
            "pipe:1",
        ]
        process.qualityOfService = .utility
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputPipe
        process.standardError = diagnostic.writer
        do {
            try process.run()
        } catch {
            diagnostic.close()
            throw MediaIOError.ffmpegUnavailable(error.localizedDescription)
        }
        outputPipe.fileHandleForWriting.closeFile()
        diagnostic.closeParentWriter()
    }

    deinit { close() }

    func read(maxFrameCount: Int) throws -> TimedPlanarAudioBlock? {
        guard !closed else { return nil }
        guard maxFrameCount > 0 else {
            throw MediaIOError.readerFailed("maxFrameCount must be positive")
        }
        let bytesPerFrame = descriptor.channelCount * MemoryLayout<Float>.size
        let (targetBytes, overflow) = maxFrameCount.multipliedReportingOverflow(by: bytesPerFrame)
        guard !overflow else { throw MediaIOError.readerFailed("FFmpeg read size overflow") }

        while pendingBytes.count < targetBytes {
            let data = try readAvailable(upToCount: min(
                Self.pipeReadSize,
                targetBytes - pendingBytes.count
            ))
            guard !data.isEmpty else { break }
            pendingBytes.append(data)
        }

        let availableFrames = min(maxFrameCount, pendingBytes.count / bytesPerFrame)
        if availableFrames == 0 {
            guard pendingBytes.isEmpty else {
                failAndClose()
                throw MediaIOError.ffmpegFailed("decoder ended with an incomplete Float32 frame")
            }
            try finishAtEOF()
            return nil
        }

        let byteCount = availableFrames * bytesPerFrame
        let valueCount = availableFrames * descriptor.channelCount
        var interleaved = [Float](repeating: 0, count: valueCount)
        _ = interleaved.withUnsafeMutableBytes { destination in
            pendingBytes.copyBytes(to: destination, count: byteCount)
        }
        pendingBytes.removeFirst(byteCount)
        var channels = Array(
            repeating: [Float](repeating: 0, count: availableFrames),
            count: descriptor.channelCount
        )
        for frame in 0..<availableFrames {
            let base = frame * descriptor.channelCount
            for channel in 0..<descriptor.channelCount {
                channels[channel][frame] = interleaved[base + channel]
            }
        }
        let audio = try PlanarAudioBlock(channels: channels)
        let block = TimedPlanarAudioBlock(audio: audio, presentationFrame: nextFrame)
        nextFrame += Int64(availableFrames)
        return block
    }

    func close() {
        guard !closed else { return }
        closed = true
        if !reachedCleanEOF { stopProcess() }
        outputPipe.fileHandleForReading.closeFile()
        diagnostic.close()
    }

    private func readAvailable(upToCount count: Int) throws -> Data {
        let descriptor = outputPipe.fileHandleForReading.fileDescriptor
        while true {
            if Task.isCancelled {
                failAndClose()
                throw CancellationError()
            }
            var value = pollfd(
                fd: descriptor,
                events: Int16(POLLIN | POLLHUP | POLLERR),
                revents: 0
            )
            let status = Darwin.poll(&value, 1, 100)
            if status > 0 {
                return try outputPipe.fileHandleForReading.read(upToCount: count) ?? Data()
            }
            if status == 0 { continue }
            if errno == EINTR { continue }
            failAndClose()
            throw MediaIOError.readerFailed("FFmpeg pipe poll failed: \(String(cString: strerror(errno)))")
        }
    }

    private func finishAtEOF() throws {
        guard !reachedCleanEOF else { return }
        for _ in 0..<100 where process.isRunning { usleep(10_000) }
        guard !process.isRunning else {
            failAndClose()
            throw MediaIOError.ffmpegFailed("decoder did not exit after closing its PCM pipe")
        }
        guard process.terminationStatus == 0 else {
            let detail = capturedError()
            failAndClose()
            throw MediaIOError.ffmpegFailed(
                detail.isEmpty
                    ? "decoder exited with status \(process.terminationStatus)"
                    : detail
            )
        }
        reachedCleanEOF = true
    }

    private func capturedError() -> String {
        diagnostic.message()
    }

    private func failAndClose() {
        reachedCleanEOF = false
        close()
    }

    private func stopProcess() {
        if process.isRunning {
            process.terminate()
            for _ in 0..<50 where process.isRunning { usleep(10_000) }
            if process.isRunning {
                kill(process.processIdentifier, SIGKILL)
                for _ in 0..<50 where process.isRunning { usleep(10_000) }
            }
        }
    }
}
