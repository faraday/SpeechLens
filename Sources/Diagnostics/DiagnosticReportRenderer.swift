// SPDX-License-Identifier: Apache-2.0

import Foundation

public enum DiagnosticReportRenderer {
    public static func render(_ report: DiagnosticReport) -> String {
        var lines = [
            "SpeechLens Support Report",
            "Schema: \(report.schemaVersion)",
            "Report ID: \(report.reportID.uuidString)",
            "Started: \(timestamp(report.startedAt))",
            "Updated: \(timestamp(report.updatedAt))",
            "",
            "[Application]",
            "Version: \(report.environment.appVersion)",
            "Build: \(report.environment.appBuild)",
            "macOS: \(report.environment.macOSVersion)",
            "Hardware: \(report.environment.hardwareModel)",
            "Processors: \(report.environment.processorCount)",
            "Memory GiB: \(report.environment.physicalMemoryGiB)",
        ]
        if let hardware = report.environment.hardware {
            lines += [
                "CPU physical cores: \(hardware.cpuPhysicalCores)",
                "CPU logical cores: \(hardware.cpuLogicalCores)",
                "CPU performance cores: \(optional(hardware.cpuPerformanceCores))",
                "CPU efficiency cores: \(optional(hardware.cpuEfficiencyCores))",
                "GPU: \(hardware.gpuName ?? "unknown")",
                "GPU cores: \(optional(hardware.gpuCoreCount))",
                "GPU unified memory: \(hardware.gpuHasUnifiedMemory.map(String.init) ?? "unknown")",
                "GPU max working set GiB: \(optional(hardware.gpuMaxWorkingSetGiB))",
            ]
        }
        lines += [
            "",
            "[Operation]",
            "Kind: \(report.operation.rawValue)",
            "Outcome: \(report.outcome.rawValue)",
            "Phase: \(report.phase.rawValue)",
            "Model artifact: \(report.model.artifactVersion)",
            "Model selection: \(report.model.selection.rawValue)",
        ]
        if let settings = report.settings {
            lines += [
                "Profile: \(settings.profile)",
                "Chunk seconds: \(number(settings.chunkSeconds))",
                "Overlap portion: \(number(settings.overlapPortion))",
            ]
        }
        appendMedia(report.inputMedia, label: "Input", to: &lines)
        appendMedia(report.outputMedia, label: "Output", to: &lines)
        if let plan = report.outputPlan {
            lines += [
                "", "[Output Plan]",
                "Input container: \(plan.inputContainer)",
                "Output container: \(plan.outputContainer)",
                "Codec format ID: \(plan.codecFormatID)",
                "Sample rate: \(plan.sampleRate)",
                "Channels: \(plan.channelCount)",
                "Selected stream: \(plan.selectedAudioStreamIndex)",
                "Copied streams: \(list(plan.copiedStreamIndices))",
                "Omitted auxiliary streams: \(list(plan.omittedAuxiliaryStreamIndices))",
            ]
        }
        if !report.notices.isEmpty {
            lines += ["", "[Notices]"]
            for notice in report.notices {
                var value = "\(notice.severity.rawValue): \(notice.code.rawValue)"
                if let indices = notice.streamIndices { value += " streams=\(list(indices))" }
                if let input = notice.inputContainer, let output = notice.outputContainer {
                    value += " input=\(input) output=\(output)"
                }
                lines.append(value)
            }
        }
        if let failure = report.failure {
            lines += ["", "[Failure]", "Category: \(failure.category.rawValue)", "Code: \(failure.code.rawValue)"]
        }
        if let duration = report.processingDurationSeconds {
            lines.append("Processing duration seconds: \(number(duration))")
        }
        lines += [
            "", "[Privacy]", "User audio included: no",
            "File names or paths included: no", "Raw logs or error descriptions included: no",
        ]
        return lines.joined(separator: "\n") + "\n"
    }

    private static func appendMedia(_ media: DiagnosticMediaFacts?, label: String, to lines: inout [String]) {
        guard let media else { return }
        lines += [
            "", "[\(label) Media]", "Container: \(media.container)",
            "Duration seconds: \(number(media.durationSeconds))",
            "Selected stream: \(media.selectedAudioStreamIndex)", "Sample rate: \(media.sampleRate)",
            "Channels: \(media.channelCount)", "Codec: \(media.codecFourCC)",
            "Audio tracks: \(media.audioTrackCount)", "Total tracks: \(media.totalTrackCount)",
        ]
    }

    private static func timestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private static func number(_ value: Double) -> String {
        String(format: "%.6f", locale: Locale(identifier: "en_US_POSIX"), value)
    }

    private static func list(_ values: [Int]) -> String {
        values.isEmpty ? "none" : values.map(String.init).joined(separator: ",")
    }

    private static func optional(_ value: Int?) -> String { value.map(String.init) ?? "unknown" }
}
