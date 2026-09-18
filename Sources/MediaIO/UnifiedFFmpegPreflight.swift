// SPDX-License-Identifier: Apache-2.0

import Foundation

struct UnifiedFFmpegPreflight {
    let executableURL: URL

    func verifyDecode(
        sourceURL: URL,
        source: AudioStreamDescriptor,
        streamIndex: Int
    ) async throws {
        // A 50 ms decode is a bounded capability check, not full-media validation.
        let arguments = [
            "-nostdin", "-hide_banner", "-loglevel", "error",
            "-threads", "1",
            "-i", sourceURL.path,
            "-map", "0:\(streamIndex)",
            "-t", "0.05",
            "-vn", "-sn", "-dn",
            "-af", "aresample=async=1:first_pts=0:min_hard_comp=0:max_soft_comp=0",
            "-c:a", "pcm_f32le",
            "-f", "f32le",
            "-",
        ]
        do {
            _ = source
            try await FFmpegCommandRunner(executableURL: executableURL).run(arguments)
        } catch {
            throw MediaIOError.ffmpegFailed(
                "selected stream \(streamIndex) could not be decoded before inference: "
                    + error.localizedDescription
            )
        }
    }

    func verifyMux(
        sourceURL: URL,
        source: AudioStreamDescriptor,
        execution: UnifiedFFmpegExecutionPlan
    ) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "speechlens-media-preflight-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: false
        )
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory
            .appendingPathComponent("probe")
            .appendingPathExtension(execution.outputPlan.outputContainer.preferredExtension)
        let silence = directory.appendingPathComponent("replacement.f32le")
        let silenceFrames = max(1, source.sampleRate / 20)
        try Data(
            count: silenceFrames * source.channelCount * MemoryLayout<Float>.size
        ).write(to: silence, options: .atomic)

        let routing = execution.routing
        let retained = routing.retainedTracks
        let replacementOutputIndex = routing.selectedOutputStreamIndex
        var arguments = [
            "-y", "-nostdin", "-hide_banner", "-loglevel", "error",
            "-threads", "1",
            "-i", sourceURL.path,
            "-f", "f32le",
            "-ar", String(source.sampleRate),
            "-ch_layout", source.channelLayout.ffmpegName
                ?? (source.channelCount == 1 ? "mono"
                    : (source.channelCount == 2 ? "stereo" : "\(source.channelCount)c")),
            "-i", silence.path,
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
        // Bound FFmpeg's interleave buffering while allowing copied streams to
        // establish timestamps during the short mux rehearsal.
        arguments += [
            "-map_metadata", "0",
            "-map_chapters", "0",
            "-t", "0.05",
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
            destination.path,
        ]
        do {
            try await FFmpegCommandRunner(executableURL: executableURL).run(arguments)
        } catch {
            throw MediaIOError.ffmpegFailed(
                "output recipe failed before inference: \(error.localizedDescription)"
            )
        }
    }
}
