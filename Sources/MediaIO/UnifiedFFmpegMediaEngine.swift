// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Foundation

/// The single media implementation backed by separately bundled FFmpeg/FFprobe
/// command-line tools. SpeechLens links no FFmpeg libraries.
package struct UnifiedFFmpegMediaEngine: Sendable {
    private let executableURL: URL?
    private let probeExecutableURL: URL?
    private let aacDecoder: any AACPCMDecoder

    package init(
        executableURL: URL? = nil,
        probeExecutableURL: URL? = nil
    ) {
        self.init(
            executableURL: executableURL,
            probeExecutableURL: probeExecutableURL,
            aacDecoder: AppleAACPCMDecoder()
        )
    }

    package init(
        executableURL: URL?,
        probeExecutableURL: URL?,
        aacDecoder: any AACPCMDecoder
    ) {
        self.executableURL = executableURL
        self.probeExecutableURL = probeExecutableURL
        self.aacDecoder = aacDecoder
    }

    package func inspect(_ url: URL) async throws -> UnifiedMediaInspection {
        let planner = try Self.planner(for: url)
        let document = try await FFprobeClient(executableURL: try probeURL()).document(url)
        try FFprobeMapping.requireFormatName(
            document, expected: planner.inputContainer.ffprobeFormatNames
        )
        return try await inspection(
            from: document,
            sourceURL: url,
            container: planner.inputContainer
        )
    }

    package func plan(
        inputURL: URL,
        info: MediaFileInfo,
        context: FFmpegInspectionContext,
        options: MediaProcessingOptions
    ) async throws -> UnifiedMediaPlan {
        _ = options
        let planner = try Self.planner(for: inputURL)
        guard context.container == planner.inputContainer,
              info.container == planner.inputContainer else {
            throw MediaIOError.unsupportedContainer(info.container.rawValue)
        }
        let preflight = UnifiedFFmpegPreflight(executableURL: try ffmpegURL())
        if info.selectedAudio.codec.formatID == kAudioFormatMPEG4AAC {
            guard context.container != .avi else {
                throw Self.aacInAVIError
            }
            let trackID = try Self.containerTrackID(
                streamIndex: info.selectedAudioStreamIndex,
                context: context
            )
            let presentation = try await aacDecoder.probe(
                sourceURL: inputURL,
                trackID: trackID
            )
            guard presentation.sampleRate == info.selectedAudio.sampleRate,
                  presentation.channelCount == info.selectedAudio.channelCount else {
                throw MediaIOError.readerFailed(
                    "Apple AAC presentation format changed after inspection"
                )
            }
        } else {
            try await preflight.verifyDecode(
                sourceURL: inputURL,
                source: info.selectedAudio,
                streamIndex: info.selectedAudioStreamIndex
            )
        }
        var failures: [String] = []
        for plan in try planner.plans(info: info, context: context) {
            do {
                try await preflight.verifyMux(
                    sourceURL: inputURL,
                    source: info.selectedAudio,
                    execution: plan.execution
                )
                return plan
            } catch {
                failures.append(
                    "\(plan.output.outputContainer.preferredExtension): "
                        + error.localizedDescription
                )
            }
        }
        let retainedInventory = info.tracks
            .filter(\.isUserFacing)
            .map {
                "\($0.streamIndex) \($0.mediaType)/\($0.codecName ?? "unknown")"
            }
            .joined(separator: ", ")
        throw MediaIOError.ffmpegFailed(
            "no output recipe retained every user-facing stream "
                + "(\(retainedInventory)): "
                + failures.joined(separator: " | ")
        )
    }

    package func validateOutputURL(_ url: URL, for plan: MediaOutputPlan) throws {
        try FFmpegRecipePlanner(inputContainer: plan.inputContainer)
            .validateOutputURL(url, plan: plan)
    }

    package func makeAudioSource(
        request: UnifiedAudioSourceRequest
    ) async throws -> sending any NativeRateAudioSource {
        guard request.context.container == request.info.container else {
            throw MediaIOError.invalidAudioFormat("FFmpeg inspection context changed")
        }
        let streamIndex = try Self.selectedAudioStreamIndex(
            streamIndex: request.info.selectedAudioStreamIndex,
            tracks: request.info.tracks
        )
        if request.info.selectedAudio.codec.formatID == kAudioFormatMPEG4AAC {
            guard request.context.container != .avi else {
                throw Self.aacInAVIError
            }
            return try await aacDecoder.open(
                sourceURL: request.url,
                trackID: try Self.containerTrackID(
                    streamIndex: streamIndex,
                    context: request.context
                ),
                descriptor: request.info.selectedAudio
            )
        }
        return try FFmpegPipeAudioSource(
            executableURL: try ffmpegURL(),
            sourceURL: request.url,
            streamIndex: streamIndex,
            descriptor: request.info.selectedAudio
        )
    }

    package func makeReplacementAudioSink(
        request: UnifiedAudioSinkRequest
    ) throws -> sending any NativeRateAudioSink {
        return try UnifiedFFmpegOutputSink(
            executableURL: try ffmpegURL(),
            outputURL: request.outputURL,
            sourceURL: request.sourceURL,
            source: request.source,
            execution: request.plan.execution
        )
    }

    package func validateOutput(
        request: UnifiedOutputValidationRequest
    ) async throws -> UnifiedOutputValidation {
        let document = try await FFprobeClient(executableURL: try probeURL())
            .document(request.outputURL)
        let inspection = try await inspection(
            from: document,
            sourceURL: request.outputURL,
            container: request.plan.output.outputContainer
        )
        return try FFmpegOutputValidator().validate(
            inspection: inspection,
            request: request
        )
    }

    private func ffmpegURL() throws -> URL {
        try executableURL ?? FFmpegExecutableResolver.resolve()
    }

    private func probeURL() throws -> URL {
        try probeExecutableURL ?? FFprobeExecutableResolver.resolve(
            ffmpegExecutableURL: try? ffmpegURL()
        )
    }

    private static func planner(for url: URL) throws -> FFmpegRecipePlanner {
        guard let container = MediaContainer.from(
            pathExtension: url.pathExtension
        ) else {
            throw MediaIOError.unsupportedContainer(url.pathExtension)
        }
        return FFmpegRecipePlanner(inputContainer: container)
    }

    private func inspection(
        from document: ProbeDocument,
        sourceURL: URL,
        container: MediaContainer
    ) async throws -> UnifiedMediaInspection {
        var aacDescriptors: [Int: AudioStreamDescriptor] = [:]
        var aacFailures: [Int: String] = [:]
        let audioStreams = document.streams.filter { $0.codecType == "audio" }
        for stream in audioStreams where stream.codecName == "aac" {
            if container == .avi {
                aacFailures[stream.index] = Self.aacInAVIMessage
                continue
            }
            do {
                guard let trackID = stream.trackID?.value else {
                    throw MediaIOError.readerFailed(
                        "AAC container track \(stream.index) has no stable track ID"
                    )
                }
                let presentation = try await aacDecoder.probe(
                    sourceURL: sourceURL,
                    trackID: trackID
                )
                aacDescriptors[stream.index] = try FFprobeMapping.audioDescriptor(
                    stream,
                    duration: presentation.durationSeconds,
                    exactDuration: presentation.durationSeconds,
                    presentationSampleRate: presentation.sampleRate,
                    presentationChannelCount: presentation.channelCount
                )
            } catch {
                aacFailures[stream.index] = error.localizedDescription
            }
        }
        if !audioStreams.isEmpty,
           audioStreams.allSatisfy({ $0.codecName == "aac" }),
           aacDescriptors.isEmpty,
           let failure = audioStreams.compactMap({ aacFailures[$0.index] }).first {
            throw MediaIOError.invalidAudioFormat(failure)
        }
        let media = try FFprobeMapping.inspection(
            from: document,
            container: container,
            audioDescriptor: { stream, duration in
                if stream.codecName == "aac" {
                    if let descriptor = aacDescriptors[stream.index] {
                        return descriptor
                    }
                    throw MediaIOError.invalidAudioFormat(
                        aacFailures[stream.index]
                            ?? "Apple AudioToolbox could not inspect the AAC track"
                    )
                }
                return try FFprobeMapping.audioDescriptor(stream, duration: duration)
            }
        )
        let trackIDs = Dictionary(
            uniqueKeysWithValues: document.streams.compactMap { stream in
                stream.trackID.map { (stream.index, $0.value) }
            }
        )
        return UnifiedMediaInspection(
            media: media,
            context: FFmpegInspectionContext(
                container: container,
                containerTrackIDsByStreamIndex: trackIDs
            )
        )
    }

    private static func containerTrackID(
        streamIndex: Int,
        context: FFmpegInspectionContext
    ) throws -> Int32 {
        guard let trackID = context.containerTrackIDsByStreamIndex[streamIndex] else {
            throw MediaIOError.readerFailed(
                "AAC stream \(streamIndex) has no stable container track ID"
            )
        }
        return trackID
    }

    private static let aacInAVIMessage =
        "AAC audio inside AVI is not supported. Convert the file to MP4 or MOV, "
        + "or extract the audio as M4A, and try again."

    private static var aacInAVIError: MediaIOError {
        .invalidAudioFormat(aacInAVIMessage)
    }

    private static func selectedAudioStreamIndex(
        streamIndex: Int,
        tracks: [MediaStream]
    ) throws -> Int {
        guard streamIndex >= 0,
              tracks.contains(where: {
                  $0.streamIndex == streamIndex && $0.isAudio
              }) else {
            throw MediaIOError.invalidAudioStreamSelection(streamIndex)
        }
        return streamIndex
    }
}
