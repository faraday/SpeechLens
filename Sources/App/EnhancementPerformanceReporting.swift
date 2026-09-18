// SPDX-License-Identifier: Apache-2.0

import AudioToolbox
import Diagnostics
import Foundation
import Inference
import MediaIO
import Processing

enum EnhancementPerformanceContainer: String, Sendable {
    case wav, aiff, caf, mp3, m4a, mp4, mov, avi, flac, other

    init(_ container: MediaContainer) {
        self = switch container {
        case .wav: .wav
        case .aiff: .aiff
        case .caf: .caf
        case .mp3: .mp3
        case .m4a: .m4a
        case .mp4: .mp4
        case .mov: .mov
        case .avi: .avi
        case .flac: .flac
        @unknown default: .other
        }
    }
}

enum EnhancementPerformanceCodecClass: String, Sendable {
    case pcm, aac, mp3, flac, alac, other

    init(formatID: AudioFormatID) {
        self = switch formatID {
        case kAudioFormatLinearPCM: .pcm
        case kAudioFormatMPEG4AAC: .aac
        case kAudioFormatMPEGLayer3: .mp3
        case kAudioFormatFLAC: .flac
        case kAudioFormatAppleLossless: .alac
        default: .other
        }
    }
}

enum EnhancementBuildConfiguration: String, Sendable {
    case debug, release
}

struct EnhancementPerformanceBuildContext: Sendable, Equatable {
    let buildConfiguration: EnhancementBuildConfiguration
    let environment: String

    static func load(bundle: Bundle = .main) -> Self? {
        guard
            let configurationValue = bundle.object(
                forInfoDictionaryKey: "SpeechLensBuildConfiguration"
            ) as? String,
            let buildConfiguration = EnhancementBuildConfiguration(
                rawValue: configurationValue
            ),
            let environment = bundle.object(
                forInfoDictionaryKey: "SpeechLensSentryEnvironment"
            ) as? String,
            ["development", "qa", "production"].contains(environment),
            environment != "production" || buildConfiguration == .release
        else { return nil }
        return Self(
            buildConfiguration: buildConfiguration,
            environment: environment
        )
    }
}

struct EnhancementPerformanceRecord: Sendable, Equatable {
    static let schemaVersion = 3
    static let effectiveTelemetrySampleRate = 1.0

    let selectedInputAudioDurationSeconds: Double
    let processingTotalSeconds: Double
    let preflightSeconds: Double
    let enhancingSeconds: Double
    let finalizingSeconds: Double
    let validatingSeconds: Double
    let enhancementPassSeconds: Double
    let realTimeFactor: Double
    let averageChannelEnhancementPassSeconds: Double
    let averageChannelRealTimeFactor: Double
    let inputAudioSampleRateHz: Int
    let channelCount: Int
    let inputContainer: EnhancementPerformanceContainer
    let outputContainer: EnhancementPerformanceContainer
    let inputCodecClass: EnhancementPerformanceCodecClass
    let outputCodecClass: EnhancementPerformanceCodecClass
    let processingProfile: String
    let chunkSeconds: Double
    let overlapPortion: Double
    let modelArtifactVersion: String
    let modelSelection: String
    let appVersion: String
    let appBuild: String
    let buildConfiguration: EnhancementBuildConfiguration
    let environment: String
    let macOSVersion: String
    let hardwareModel: String
    let processorCount: Int
    let physicalMemoryGiB: Int
    let hardware: DiagnosticHardwareFacts?

    init?(
        result: MediaProcessingResult,
        profile: ProcessingProfile,
        settings: InferenceSettings,
        modelArtifactVersion: String,
        modelSelection: DiagnosticModelSelection,
        diagnosticEnvironment: DiagnosticEnvironment,
        buildContext: EnhancementPerformanceBuildContext
    ) {
        guard result.timings.isConsistent else { return nil }
        let selectedDuration = result.inputInfo.selectedAudio.durationSeconds
        let processingTotal = result.timings.total.telemetrySeconds
        let preflight = result.timings.preflight.telemetrySeconds
        let enhancing = result.timings.enhancing.telemetrySeconds
        let finalizing = result.timings.finalizing.telemetrySeconds
        let validating = result.timings.validating.telemetrySeconds
        let enhancementPass = result.timings.enhancementPass.telemetrySeconds
        let channelEnhancementPasses =
            result.timings.channelEnhancementPasses.map(\.telemetrySeconds)
        let numericValues = [
            selectedDuration,
            processingTotal,
            preflight,
            enhancing,
            finalizing,
            validating,
            enhancementPass,
            settings.chunkSeconds,
            settings.overlapPortion,
        ]
        guard
            selectedDuration > 0,
            numericValues.allSatisfy({ $0.isFinite && $0 >= 0 }),
            channelEnhancementPasses.count
                == result.inputInfo.selectedAudio.channelCount,
            channelEnhancementPasses.allSatisfy({
                $0.isFinite && $0 >= 0
            }),
            result.inputInfo.selectedAudio.sampleRate > 0,
            result.inputInfo.selectedAudio.channelCount > 0,
            isSafeDimension(profile.rawValue),
            isSafeDimension(modelArtifactVersion),
            isSafeDimension(modelSelection.rawValue),
            isSafeDimension(diagnosticEnvironment.appVersion),
            isSafeDimension(diagnosticEnvironment.appBuild),
            isSafeDimension(diagnosticEnvironment.macOSVersion),
            isSafeDimension(diagnosticEnvironment.hardwareModel),
            isSafeOptionalDimension(diagnosticEnvironment.hardware?.gpuName),
            buildContext.environment != "production"
                || buildContext.buildConfiguration == .release
        else { return nil }

        let rtf = enhancementPass / selectedDuration
        let averageChannelPass = channelEnhancementPasses.reduce(0, +)
            / Double(channelEnhancementPasses.count)
        let averageChannelRTF = averageChannelPass / selectedDuration
        guard
            rtf.isFinite && rtf >= 0,
            averageChannelPass.isFinite && averageChannelPass >= 0,
            averageChannelRTF.isFinite && averageChannelRTF >= 0
        else { return nil }

        selectedInputAudioDurationSeconds = selectedDuration
        processingTotalSeconds = processingTotal
        preflightSeconds = preflight
        enhancingSeconds = enhancing
        finalizingSeconds = finalizing
        validatingSeconds = validating
        enhancementPassSeconds = enhancementPass
        realTimeFactor = rtf
        averageChannelEnhancementPassSeconds = averageChannelPass
        averageChannelRealTimeFactor = averageChannelRTF
        inputAudioSampleRateHz = result.inputInfo.selectedAudio.sampleRate
        channelCount = result.inputInfo.selectedAudio.channelCount
        inputContainer = EnhancementPerformanceContainer(
            result.outputPlan.inputContainer
        )
        outputContainer = EnhancementPerformanceContainer(
            result.outputPlan.outputContainer
        )
        inputCodecClass = EnhancementPerformanceCodecClass(
            formatID: result.inputInfo.selectedAudio.codec.formatID
        )
        outputCodecClass = EnhancementPerformanceCodecClass(
            formatID: result.outputPlan.audioEncoding.codecFormatID
        )
        processingProfile = profile.rawValue
        chunkSeconds = settings.chunkSeconds
        overlapPortion = settings.overlapPortion
        self.modelArtifactVersion = modelArtifactVersion
        self.modelSelection = modelSelection.rawValue
        appVersion = diagnosticEnvironment.appVersion
        appBuild = diagnosticEnvironment.appBuild
        buildConfiguration = buildContext.buildConfiguration
        environment = buildContext.environment
        macOSVersion = diagnosticEnvironment.macOSVersion
        hardwareModel = diagnosticEnvironment.hardwareModel
        processorCount = diagnosticEnvironment.processorCount
        physicalMemoryGiB = diagnosticEnvironment.physicalMemoryGiB
        hardware = diagnosticEnvironment.hardware
    }

    static let allowedDimensionNames: Set<String> = [
        "event_schema_version",
        "input_container",
        "output_container",
        "input_codec_class",
        "output_codec_class",
        "processing_profile",
        "model_artifact_version",
        "model_selection",
        "app_version",
        "app_build",
        "build_configuration",
        "telemetry_environment",
        "macos_version",
        "hardware_model",
        "processor_count",
        "physical_memory_gib",
        "cpu_physical_cores",
        "cpu_logical_cores",
        "cpu_performance_cores",
        "cpu_efficiency_cores",
        "gpu_name",
        "gpu_core_count",
        "gpu_has_unified_memory",
        "gpu_max_working_set_gib",
        "input_audio_sample_rate_hz",
        "channel_count",
        "chunk_seconds",
        "overlap_portion",
        "effective_telemetry_sample_rate",
    ]

    static let allowedMeasurementNames: Set<String> = [
        "selected_input_audio_duration_seconds",
        "processing_total_seconds",
        "preflight_seconds",
        "enhancing_seconds",
        "finalizing_seconds",
        "validating_seconds",
        "enhancement_pass_seconds",
        "real_time_factor",
        "avg_channel_enhancement_pass_seconds",
        "avg_channel_real_time_factor",
    ]

    var dimensions: [String: String] {
        var values = [
            "event_schema_version": String(Self.schemaVersion),
            "input_container": inputContainer.rawValue,
            "output_container": outputContainer.rawValue,
            "input_codec_class": inputCodecClass.rawValue,
            "output_codec_class": outputCodecClass.rawValue,
            "processing_profile": processingProfile,
            "model_artifact_version": modelArtifactVersion,
            "model_selection": modelSelection,
            "app_version": appVersion,
            "app_build": appBuild,
            "build_configuration": buildConfiguration.rawValue,
            "telemetry_environment": environment,
            "macos_version": macOSVersion,
            "hardware_model": hardwareModel,
            "processor_count": String(processorCount),
            "physical_memory_gib": String(physicalMemoryGiB),
            "input_audio_sample_rate_hz": String(inputAudioSampleRateHz),
            "channel_count": String(channelCount),
            "chunk_seconds": String(chunkSeconds),
            "overlap_portion": String(overlapPortion),
            "effective_telemetry_sample_rate": String(
                Self.effectiveTelemetrySampleRate
            ),
        ]
        if let hardware {
            values["cpu_physical_cores"] = String(hardware.cpuPhysicalCores)
            values["cpu_logical_cores"] = String(hardware.cpuLogicalCores)
            values["cpu_performance_cores"] = hardware.cpuPerformanceCores.map(String.init)
            values["cpu_efficiency_cores"] = hardware.cpuEfficiencyCores.map(String.init)
            values["gpu_name"] = hardware.gpuName
            values["gpu_core_count"] = hardware.gpuCoreCount.map(String.init)
            values["gpu_has_unified_memory"] = hardware.gpuHasUnifiedMemory.map(String.init)
            values["gpu_max_working_set_gib"] = hardware.gpuMaxWorkingSetGiB.map(String.init)
        }
        return values
    }

    var measurements: [String: Double] {
        [
            "selected_input_audio_duration_seconds":
                selectedInputAudioDurationSeconds,
            "processing_total_seconds": processingTotalSeconds,
            "preflight_seconds": preflightSeconds,
            "enhancing_seconds": enhancingSeconds,
            "finalizing_seconds": finalizingSeconds,
            "validating_seconds": validatingSeconds,
            "enhancement_pass_seconds": enhancementPassSeconds,
            "real_time_factor": realTimeFactor,
            "avg_channel_enhancement_pass_seconds":
                averageChannelEnhancementPassSeconds,
            "avg_channel_real_time_factor":
                averageChannelRealTimeFactor,
        ]
    }

    var validatedPayload: EnhancementPerformancePayload? {
        EnhancementPerformancePayload(
            dimensions: dimensions,
            measurements: measurements
        )
    }
}

struct EnhancementPerformancePayload: Sendable, Equatable {
    let dimensions: [String: String]
    let measurements: [String: Double]

    init?(
        dimensions: [String: String],
        measurements: [String: Double]
    ) {
        guard
            Set(dimensions.keys).isSubset(
                of: EnhancementPerformanceRecord.allowedDimensionNames
            ),
            dimensions.values.allSatisfy(isSafeDimension),
            Set(measurements.keys)
                == EnhancementPerformanceRecord.allowedMeasurementNames,
            measurements.values.allSatisfy({
                $0.isFinite && $0 >= 0
            })
        else { return nil }
        self.dimensions = dimensions
        self.measurements = measurements
    }
}

@MainActor
protocol AppEnhancementPerformanceReporting: AnyObject {
    func submit(_ record: EnhancementPerformanceRecord)
}

@MainActor
final class NoOpEnhancementPerformanceReporter:
    AppEnhancementPerformanceReporting
{
    func submit(_ record: EnhancementPerformanceRecord) {}
}

private extension Duration {
    var telemetrySeconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

private func isSafeOptionalDimension(_ value: String?) -> Bool {
    value.map(isSafeDimension) ?? true
}

private func isSafeDimension(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= 128
        && !value.contains("/")
        && !value.contains("\\")
        && !value.contains("\n")
        && !value.contains("\r")
        && !value.contains("://")
}
