// SPDX-License-Identifier: Apache-2.0

import Foundation
import Diagnostics
import Inference
import MediaIO
import Processing
import ArgumentParser
import Darwin

@main
struct SpeechLensCLI: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "speechlens-cli",
        abstract: "Headless speech enhancement runner for SpeechLens."
    )
    
    @Option(name: .shortAndLong, help: "Input WAV, AIFF, CAF, FLAC, MP3, M4A, MP4, MOV, or AVI file.")
    var input: String
    
    @Option(name: .shortAndLong, help: "Output file; its extension must match the planned output container.")
    var output: String
    
    @Option(name: .long, help: "Length of audio chunks in seconds.")
    var chunkSeconds: Double = InferenceSettings.standard.chunkSeconds
    
    @Option(name: .long, help: "Overlap portion [0.0, 0.5].")
    var overlapPortion: Double = InferenceSettings.standard.overlapPortion

    @Flag(name: .long, help: "Use Strict Mode with the fast-bitcast-scalar selective scan.")
    var strict = false
    
    @Option(name: .shortAndLong, help: "Path to model weights (.safetensors). Defaults to SPEECHLENS_WEIGHTS, the app model cache, then ./model_mlx.safetensors.")
    var weights: String?

    @Option(name: .long, help: "Write a sanitized operation diagnostic JSON report to this path.")
    var diagnosticsOut: String?

    func run() async throws {
        let inputURL = URL(fileURLWithPath: input)
        let outputURL = URL(fileURLWithPath: output)
        let processingOptions = MediaProcessingOptions.standard
        let settings: InferenceSettings
        do {
            settings = try InferenceSettings(
                chunkSeconds: chunkSeconds,
                overlapPortion: overlapPortion
            )
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        let weightsURL: URL
        do {
            weightsURL = try CLIWeightsResolver.resolve(explicitPath: weights)
        } catch {
            throw ValidationError(error.localizedDescription)
        }

        let diagnostics: DiagnosticRecorder?
        if let diagnosticsOut {
            let path = NSString(string: diagnosticsOut).expandingTildeInPath
            let recorder = DiagnosticRecorder(
                store: DiagnosticSnapshotStore(fileURL: URL(fileURLWithPath: path))
            )
            do {
                try recorder.begin(
                    operation: .mediaEnhancement,
                    modelVersion: "external",
                    modelSelection: .explicitWeights,
                    settings: DiagnosticSettings(profile: "cli", settings: settings),
                    phase: .preparing
                )
            } catch {
                throw ValidationError(
                    "Unable to create diagnostics report: \(error.localizedDescription)"
                )
            }
            diagnostics = recorder
        } else {
            diagnostics = nil
        }

        let job: PreparedMediaJob
        do {
            let preparer = MediaJobPreparer()
            let inspection = try await preparer.inspect(inputURL: inputURL)
            job = try await preparer.prepare(
                inspection: inspection,
                selectedAudioStreamIndex: inspection.mediaInspection.suggestedAudioStreamIndex,
                options: processingOptions
            ) { _ in outputURL }
        } catch {
            diagnostics?.finishFailure(error, category: .preparation)
            if let error = error as? ValidationError { throw error }
            throw ValidationError(error.localizedDescription)
        }
        diagnostics?.recordPreparedJob(job)
        for notice in job.outputPlan.notices {
            let message = CLIMediaNoticePresentation.message(for: notice)
            FileHandle.standardError.write(Data("Info: \(message)\n".utf8))
        }
        print("SpeechLens CLI: Enhancing \(inputURL.lastPathComponent) using \(weightsURL.lastPathComponent)...")
        let pipeline: MediaFileEnhancementPipeline
        do {
            pipeline = MediaFileEnhancementPipeline(
                enhancer: try MambaEnhancer(
                    modelWeightsURL: weightsURL,
                    mode: strict ? .strict : .standard
                )
            )
        } catch {
            diagnostics?.finishFailure(error, category: .modelLoad)
            throw error
        }
        let reporter = CLIProgressReporter()
        let processingStarted = Date()
        let processingTask = Task {
            try await pipeline.process(
                job: job,
                settings: settings,
                progress: {
                    reporter.report($0)
                    diagnostics?.recordProgress($0)
                }
            )
        }
        let signalCancellation = SignalCancellation {
            processingTask.cancel()
        }
        defer { signalCancellation.stop() }
        do {
            let result = try await processingTask.value
            diagnostics?.recordResult(
                result
            )
            diagnostics?.finishCompleted(
                processingDuration: Date().timeIntervalSince(processingStarted)
            )
        } catch is CancellationError {
            diagnostics?.finishCancelled()
            throw CancellationError()
        } catch {
            diagnostics?.finishFailure(error, category: .processing)
            throw error
        }
        reporter.reportCompletion()
        print("Success: \(outputURL.path)")
    }
}

private enum CLIMediaNoticePresentation {
    static func message(for notice: MediaOutputNotice) -> String {
        switch notice {
        case .auxiliaryStreamsOmitted:
            return "Auxiliary timecode, data, attachment, or opaque streams were not carried to the output."
        case .fallbackContainer(_, let output):
            return "The media was written as \(output.preferredExtension.uppercased()) "
                + "because the original container could not carry the native-rate output."
        }
    }
}

// SAFETY: All mutable reporting state is protected by `lock`.
private final class CLIProgressReporter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastPercentage = -1
    private var currentPhase: MediaProcessingPhase?
    private var phaseStarted = ContinuousClock.now
    private let processingStarted = ContinuousClock.now

    func report(_ progress: MediaProcessingProgress) {
        let percentage = Int((progress.fractionCompleted * 100).rounded(.down))
        let lines = lock.withLock { () -> [String] in
            var lines = [String]()
            if currentPhase != progress.phase {
                if let currentPhase {
                    lines.append(Self.timingLine(
                        phase: currentPhase,
                        duration: phaseStarted.duration(to: .now)
                    ))
                }
                currentPhase = progress.phase
                phaseStarted = .now
                lastPercentage = -1
            }
            guard percentage == 100 || percentage >= lastPercentage + 5 else { return lines }
            lastPercentage = percentage
            lines.append("\(Self.label(progress.phase)): \(percentage)%")
            return lines
        }
        for line in lines {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    func reportCompletion() {
        let lines = lock.withLock { () -> [String] in
            var lines = [String]()
            if let currentPhase {
                lines.append(Self.timingLine(
                    phase: currentPhase,
                    duration: phaseStarted.duration(to: .now)
                ))
                self.currentPhase = nil
            }
            lines.append(String(
                format: "TotalTiming: %.3f seconds",
                Self.seconds(processingStarted.duration(to: .now))
            ))
            return lines
        }
        for line in lines {
            FileHandle.standardError.write(Data("\(line)\n".utf8))
        }
    }

    private static func label(_ phase: MediaProcessingPhase) -> String {
        switch phase {
        case .preflight: "Preparing"
        case .enhancing: "Enhancing"
        case .finalizing: "Finalizing"
        case .validating: "Validating"
        case .committing: "Committing"
        }
    }

    private static func timingLine(
        phase: MediaProcessingPhase,
        duration: Duration
    ) -> String {
        String(format: "PhaseTiming[%@]: %.3f seconds", label(phase), seconds(duration))
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private final class SignalCancellation {
    private var sources = [DispatchSourceSignal]()

    init(cancel: @escaping @Sendable () -> Void) {
        for signalNumber in [SIGINT, SIGTERM] {
            Darwin.signal(signalNumber, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global())
            source.setEventHandler(handler: cancel)
            source.resume()
            sources.append(source)
        }
    }

    func stop() {
        for source in sources { source.cancel() }
        sources.removeAll()
        Darwin.signal(SIGINT, SIG_DFL)
        Darwin.signal(SIGTERM, SIG_DFL)
    }

    deinit { stop() }
}

enum CLIWeightsResolver {
    static let environmentKey = "SPEECHLENS_WEIGHTS"
    static let defaultFileName = "model_mlx.safetensors"

    static func resolve(
        explicitPath: String?,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        currentDirectoryURL: URL = URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
        applicationSupportURL: URL? = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
        fileExists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }
    ) throws -> URL {
        if let explicitPath, !explicitPath.isEmpty {
            let url = fileURL(for: explicitPath, relativeTo: currentDirectoryURL)
            guard fileExists(url.path) else {
                throw CLIWeightsResolutionError.explicitPathMissing(url)
            }
            return url
        }

        if let environmentPath = environment[environmentKey], !environmentPath.isEmpty {
            let url = fileURL(for: environmentPath, relativeTo: currentDirectoryURL)
            guard fileExists(url.path) else {
                throw CLIWeightsResolutionError.environmentPathMissing(key: environmentKey, url: url)
            }
            return url
        }

        let appCacheURL = cachedWeightsURL(applicationSupportURL: applicationSupportURL)
        if fileExists(appCacheURL.path) {
            return appCacheURL
        }

        let currentDirectoryURL = currentDirectoryURL.appendingPathComponent(defaultFileName)
        if fileExists(currentDirectoryURL.path) {
            return currentDirectoryURL
        }

        throw CLIWeightsResolutionError.noWeightsFound(
            environmentKey: environmentKey,
            appCacheURL: appCacheURL,
            currentDirectoryURL: currentDirectoryURL
        )
    }

    private static func cachedWeightsURL(applicationSupportURL: URL?) -> URL {
        let base = applicationSupportURL
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base
            .appendingPathComponent("SpeechLens/Models", isDirectory: true)
            .appendingPathComponent(defaultFileName)
    }

    private static func fileURL(for path: String, relativeTo currentDirectoryURL: URL) -> URL {
        let expandedPath = NSString(string: path).expandingTildeInPath
        if expandedPath.hasPrefix("/") {
            return URL(fileURLWithPath: expandedPath)
        }
        return currentDirectoryURL.appendingPathComponent(expandedPath)
    }
}

enum CLIWeightsResolutionError: Error, LocalizedError, Equatable {
    case explicitPathMissing(URL)
    case environmentPathMissing(key: String, url: URL)
    case noWeightsFound(environmentKey: String, appCacheURL: URL, currentDirectoryURL: URL)

    var errorDescription: String? {
        switch self {
        case .explicitPathMissing(let url):
            return "Model weights not found at --weights path: \(url.path)"
        case .environmentPathMissing(let key, let url):
            return "Model weights not found at \(key) path: \(url.path)"
        case let .noWeightsFound(environmentKey, appCacheURL, currentDirectoryURL):
            return """
            Model weights not found.
            Provide --weights /path/to/model_mlx.safetensors, set \(environmentKey), download the model in the app, or place model_mlx.safetensors in the current directory.
            Searched:
              - \(appCacheURL.path)
              - \(currentDirectoryURL.path)
            """
        }
    }
}
