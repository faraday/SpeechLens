// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference
import MediaIO
import Processing

public enum DiagnosticOperation: String, Codable, Sendable, Equatable {
    case mediaEnhancement
    case modelDownload
}

public enum DiagnosticOutcome: String, Codable, Sendable, Equatable {
    case inProgress
    case completed
    case failed
    case cancelled
    case interrupted
}

public enum DiagnosticPhase: String, Codable, Sendable, Equatable {
    case preparing
    case selectingAudioTrack
    case loadingModel
    case processingPreflight
    case processingEnhancing
    case processingFinalizing
    case processingValidating
    case processingCommitting
    case modelPreparing
    case modelDownloading
    case modelVerifying
    case terminal

    public init(_ phase: MediaProcessingPhase) {
        self = switch phase {
        case .preflight: .processingPreflight
        case .enhancing: .processingEnhancing
        case .finalizing: .processingFinalizing
        case .validating: .processingValidating
        case .committing: .processingCommitting
        }
    }
}

public enum DiagnosticModelSelection: String, Codable, Sendable, Equatable {
    case `default`
    case explicitWeights = "explicit_weights"
    case unavailable
}

public struct DiagnosticHardwareFacts: Codable, Sendable, Equatable {
    public let cpuPhysicalCores: Int
    public let cpuLogicalCores: Int
    public let cpuPerformanceCores: Int?
    public let cpuEfficiencyCores: Int?
    public let gpuName: String?
    public let gpuCoreCount: Int?
    public let gpuHasUnifiedMemory: Bool?
    public let gpuMaxWorkingSetGiB: Int?

    public init(
        cpuPhysicalCores: Int,
        cpuLogicalCores: Int,
        cpuPerformanceCores: Int?,
        cpuEfficiencyCores: Int?,
        gpuName: String?,
        gpuCoreCount: Int?,
        gpuHasUnifiedMemory: Bool?,
        gpuMaxWorkingSetGiB: Int?
    ) {
        self.cpuPhysicalCores = cpuPhysicalCores
        self.cpuLogicalCores = cpuLogicalCores
        self.cpuPerformanceCores = cpuPerformanceCores
        self.cpuEfficiencyCores = cpuEfficiencyCores
        self.gpuName = gpuName
        self.gpuCoreCount = gpuCoreCount
        self.gpuHasUnifiedMemory = gpuHasUnifiedMemory
        self.gpuMaxWorkingSetGiB = gpuMaxWorkingSetGiB
    }
}

public struct DiagnosticEnvironment: Codable, Sendable, Equatable {
    public let appVersion: String
    public let appBuild: String
    public let macOSVersion: String
    public let hardwareModel: String
    public let processorCount: Int
    public let physicalMemoryGiB: Int
    public let hardware: DiagnosticHardwareFacts?

    public init(
        appVersion: String,
        appBuild: String,
        macOSVersion: String,
        hardwareModel: String,
        processorCount: Int,
        physicalMemoryGiB: Int,
        hardware: DiagnosticHardwareFacts? = nil
    ) {
        self.appVersion = appVersion
        self.appBuild = appBuild
        self.macOSVersion = macOSVersion
        self.hardwareModel = hardwareModel
        self.processorCount = processorCount
        self.physicalMemoryGiB = physicalMemoryGiB
        self.hardware = hardware
    }

    public static func current(
        bundle: Bundle = .main,
        processInfo: ProcessInfo = .processInfo,
        hardware: DiagnosticHardwareFacts? = DiagnosticHardwareFacts.current()
    ) -> Self {
        let version = processInfo.operatingSystemVersion
        return Self(
            appVersion: bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString")
                as? String ?? "development",
            appBuild: bundle.object(forInfoDictionaryKey: "CFBundleVersion")
                as? String ?? "development",
            macOSVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
            hardwareModel: DiagnosticHardwareFacts.hardwareModelName() ?? "unknown",
            processorCount: processInfo.processorCount,
            physicalMemoryGiB: Int(
                (processInfo.physicalMemory + 512 * 1_024 * 1_024)
                    / (1_024 * 1_024 * 1_024)
            ),
            hardware: hardware
        )
    }

}

public struct DiagnosticModel: Codable, Sendable, Equatable {
    public let artifactVersion: String
    public let selection: DiagnosticModelSelection

    public init(artifactVersion: String, selection: DiagnosticModelSelection) {
        self.artifactVersion = artifactVersion
        self.selection = selection
    }
}

public struct DiagnosticSettings: Codable, Sendable, Equatable {
    public let profile: String
    public let chunkSeconds: Double
    public let overlapPortion: Double

    public init(profile: String, settings: InferenceSettings) {
        self.profile = profile
        chunkSeconds = settings.chunkSeconds
        overlapPortion = settings.overlapPortion
    }
}

public struct DiagnosticMediaFacts: Codable, Sendable, Equatable {
    public let container: String
    public let durationSeconds: Double
    public let selectedAudioStreamIndex: Int
    public let sampleRate: Int
    public let channelCount: Int
    public let codecFourCC: String
    public let audioTrackCount: Int
    public let totalTrackCount: Int

    public init(_ info: MediaFileInfo) {
        container = info.container.rawValue
        durationSeconds = info.durationSeconds
        selectedAudioStreamIndex = info.selectedAudioStreamIndex
        sampleRate = info.selectedAudio.sampleRate
        channelCount = info.selectedAudio.channelCount
        codecFourCC = info.selectedAudio.codec.fourCC
        audioTrackCount = info.audioTrackCount
        totalTrackCount = info.tracks.count
    }
}

public struct DiagnosticOutputPlan: Codable, Sendable, Equatable {
    public let inputContainer: String
    public let outputContainer: String
    public let codecFormatID: UInt32
    public let sampleRate: Int
    public let channelCount: Int
    public let selectedAudioStreamIndex: Int
    public let copiedStreamIndices: [Int]
    public let omittedAuxiliaryStreamIndices: [Int]

    public init(_ plan: MediaOutputPlan) {
        inputContainer = plan.inputContainer.rawValue
        outputContainer = plan.outputContainer.rawValue
        codecFormatID = plan.audioEncoding.codecFormatID
        sampleRate = plan.audioEncoding.sampleRate
        channelCount = plan.audioEncoding.channelCount
        selectedAudioStreamIndex = plan.selectedAudioStreamIndex
        copiedStreamIndices = plan.copiedStreamIndices
        omittedAuxiliaryStreamIndices = plan.omittedAuxiliaryStreamIndices
    }
}

public enum DiagnosticNoticeCode: String, Codable, Sendable, Equatable {
    case auxiliaryStreamsOmitted = "media.auxiliary_streams_omitted"
    case fallbackContainer = "media.fallback_container"
    case playbackPreviewFileMissing = "playback.preview_file_missing"
}

public struct DiagnosticNotice: Codable, Sendable, Equatable {
    public let code: DiagnosticNoticeCode
    public let severity: MediaOutputNoticeSeverity
    public let streamIndices: [Int]?
    public let inputContainer: String?
    public let outputContainer: String?

    public init(
        code: DiagnosticNoticeCode,
        severity: MediaOutputNoticeSeverity,
        streamIndices: [Int]? = nil,
        inputContainer: String? = nil,
        outputContainer: String? = nil
    ) {
        self.code = code
        self.severity = severity
        self.streamIndices = streamIndices
        self.inputContainer = inputContainer
        self.outputContainer = outputContainer
    }

    public init(_ notice: MediaOutputNotice) {
        switch notice {
        case .auxiliaryStreamsOmitted(let indices):
            self.init(code: .auxiliaryStreamsOmitted, severity: notice.severity, streamIndices: indices)
        case .fallbackContainer(let input, let output):
            self.init(
                code: .fallbackContainer,
                severity: notice.severity,
                inputContainer: input.rawValue,
                outputContainer: output.rawValue
            )
        }
    }
}

public struct DiagnosticReport: Codable, Sendable, Equatable {
    public static let currentSchemaVersion = 2

    public let schemaVersion: Int
    public let reportID: UUID
    public let startedAt: Date
    public internal(set) var updatedAt: Date
    public let environment: DiagnosticEnvironment
    public let operation: DiagnosticOperation
    public internal(set) var outcome: DiagnosticOutcome
    public internal(set) var phase: DiagnosticPhase
    public internal(set) var model: DiagnosticModel
    public internal(set) var settings: DiagnosticSettings?
    public internal(set) var inputMedia: DiagnosticMediaFacts?
    public internal(set) var outputMedia: DiagnosticMediaFacts?
    public internal(set) var outputPlan: DiagnosticOutputPlan?
    public internal(set) var notices: [DiagnosticNotice]
    public internal(set) var failure: DiagnosticFailure?
    public internal(set) var processingDurationSeconds: Double?
}
