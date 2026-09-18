// SPDX-License-Identifier: Apache-2.0

import Darwin
import Foundation

struct FFmpegCommandRunner: Sendable {
    let executableURL: URL

    func run(_ arguments: [String]) async throws {
        _ = try await invoke(arguments, captureStandardOutput: false)
    }

    func captureStandardOutput(_ arguments: [String]) async throws -> Data {
        try await invoke(arguments, captureStandardOutput: true).standardOutput
    }

    private func invoke(
        _ arguments: [String],
        captureStandardOutput: Bool
    ) async throws -> FFmpegInvocationResult {
        let invocation = FFmpegInvocation(
            executableURL: executableURL,
            arguments: arguments,
            captureStandardOutput: captureStandardOutput
        )
        let result = try await withTaskCancellationHandler {
            try await Task.detached(priority: .utility) { try invocation.run() }.value
        } onCancel: {
            invocation.cancel()
        }
        guard result.status == 0 else {
            let detail = result.standardError.isEmpty
                ? "process exited with status \(result.status)"
                : result.standardError
            throw MediaIOError.ffmpegFailed(detail)
        }
        return result
    }
}

/// Actively drains helper stderr so the child cannot block, while retaining
/// only a small diagnostic suffix in memory.
// SAFETY: All mutable diagnostic and process state is protected by `lock`.
final class BoundedProcessDiagnosticTail: @unchecked Sendable {
    let writer: FileHandle

    private let reader: FileHandle
    private let limit: Int
    private let lock = NSLock()
    private let drainGroup = DispatchGroup()
    private var tail = Data()
    private var writerClosed = false
    private var readerClosed = false

    init(limit: Int = 16_384) {
        let pipe = Pipe()
        reader = pipe.fileHandleForReading
        writer = pipe.fileHandleForWriting
        self.limit = max(1, limit)
        drainGroup.enter()
        DispatchQueue.global(qos: .utility).async { [self] in
            drain()
            drainGroup.leave()
        }
    }

    deinit { close() }

    func closeParentWriter() {
        let shouldClose = lock.withLock { () -> Bool in
            guard !writerClosed else { return false }
            writerClosed = true
            return true
        }
        if shouldClose { try? writer.close() }
    }

    func message() -> String {
        closeParentWriter()
        _ = drainGroup.wait(timeout: .now() + .seconds(1))
        let data = lock.withLock { tail }
        return String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func close() {
        closeParentWriter()
        _ = drainGroup.wait(timeout: .now() + .seconds(1))
        let shouldClose = lock.withLock { () -> Bool in
            guard !readerClosed else { return false }
            readerClosed = true
            return true
        }
        if shouldClose { try? reader.close() }
    }

    private func drain() {
        while let chunk = try? reader.read(upToCount: 4_096), !chunk.isEmpty {
            lock.withLock {
                tail.append(chunk)
                if tail.count > limit { tail.removeFirst(tail.count - limit) }
            }
        }
    }
}

private struct FFmpegInvocationResult: Sendable {
    let status: Int32
    let standardOutput: Data
    let standardError: String
}

// SAFETY: All mutable cancellation and process state is protected by `lock`.
private final class FFmpegInvocation: @unchecked Sendable {
    private let executableURL: URL
    private let arguments: [String]
    private let captureStandardOutput: Bool
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    init(executableURL: URL, arguments: [String], captureStandardOutput: Bool) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.captureStandardOutput = captureStandardOutput
    }

    func run() throws -> FFmpegInvocationResult {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        process.qualityOfService = .utility
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "speechlens-helper-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: temporary,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: temporary) }
        let outputURL = temporary.appendingPathComponent("stdout.data")
        FileManager.default.createFile(atPath: outputURL.path, contents: nil)
        let outputHandle = try FileHandle(forWritingTo: outputURL)
        defer { try? outputHandle.close() }
        let diagnostic = BoundedProcessDiagnosticTail()
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = captureStandardOutput
            ? outputHandle
            : FileHandle.nullDevice
        process.standardError = diagnostic.writer

        let shouldRun = lock.withLock { () -> Bool in
            guard !cancelled else { return false }
            self.process = process
            return true
        }
        guard shouldRun else { throw CancellationError() }
        defer { lock.withLock { self.process = nil } }

        do {
            try process.run()
        } catch {
            diagnostic.close()
            throw MediaIOError.ffmpegUnavailable(error.localizedDescription)
        }
        diagnostic.closeParentWriter()
        process.waitUntilExit()
        if lock.withLock({ cancelled }) { throw CancellationError() }
        if captureStandardOutput { try outputHandle.synchronize() }
        return FFmpegInvocationResult(
            status: process.terminationStatus,
            standardOutput: captureStandardOutput
                ? ((try? Data(contentsOf: outputURL)) ?? Data())
                : Data(),
            standardError: diagnostic.message()
        )
    }

    func cancel() {
        let running = lock.withLock { () -> Process? in
            cancelled = true
            return process
        }
        Self.stop(running)
    }

    static func stop(_ process: Process?) {
        guard let process, process.isRunning else { return }
        process.terminate()
        for _ in 0..<50 where process.isRunning { usleep(10_000) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
}
