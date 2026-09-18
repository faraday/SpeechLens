// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Foundation
import Inference
import MediaIO
import Processing

public enum DiagnosticFailureCategory: String, Codable, Sendable, Equatable {
    case modelSetup
    case modelUnavailable
    case inspection
    case preparation
    case modelLoad
    case metalCompatibility
    case processing
}

public enum DiagnosticFailureCode: String, Codable, Sendable, Equatable, CaseIterable {
    case modelUnavailable = "model.unavailable"
    case modelSetupFailed = "model.setup_failed"
    case modelCacheManifestMissing = "model.cache_manifest_missing"
    case modelCacheManifestMismatch = "model.cache_manifest_mismatch"
    case modelCacheChecksumMismatch = "model.cache_checksum_mismatch"
    case modelCacheVerificationFailed = "model.cache_verification_failed"
    case modelDownloadInvalidManifest = "model.download_invalid_manifest"
    case modelDownloadMissingChecksum = "model.download_missing_checksum"
    case modelDownloadManifestMismatch = "model.download_manifest_mismatch"
    case modelDownloadChecksumMismatch = "model.download_checksum_mismatch"
    case modelDownloadMissingFile = "model.download_missing_file"
    case modelDownloadHTTPStatus = "model.download_http_status"
    case modelDownloadNetwork = "model.download_network"
    case modelDownloadInstallation = "model.download_installation"
    case modelLoadFailed = "model.load_failed"
    case metalCompatibility = "model.metal_compatibility"
    case mediaUnsupportedContainer = "media.unsupported_container"
    case mediaUnreadable = "media.unreadable"
    case mediaProtectedContent = "media.protected_content"
    case mediaMissingAudioTrack = "media.missing_audio_track"
    case mediaNoSelectableAudioTrack = "media.no_selectable_audio_track"
    case mediaInvalidAudioStreamSelection = "media.invalid_audio_stream_selection"
    case mediaInvalidAudioFormat = "media.invalid_audio_format"
    case mediaUnsupportedChannelLayout = "media.unsupported_channel_layout"
    case mediaOutputContainerMismatch = "media.output_container_mismatch"
    case mediaReaderFailed = "media.reader_failed"
    case mediaWriterFailed = "media.writer_failed"
    case mediaFFmpegUnavailable = "media.ffmpeg_unavailable"
    case mediaFFmpegFailed = "media.ffmpeg_failed"
    case processingEmptyInput = "processing.empty_input"
    case processingInvalidInputLayout = "processing.invalid_input_layout"
    case processingInconsistentSessionBlockSize = "processing.inconsistent_session_block_size"
    case processingInconsistentChannelOutput = "processing.inconsistent_channel_output"
    case processingInvalidOutputPlan = "processing.invalid_output_plan"
    case processingOutputIdentityChanged = "processing.output_identity_changed"
    case processingDestinationUnavailable = "processing.destination_unavailable"
    case processingSourceUnavailable = "processing.source_unavailable"
    case processingSourceChanged = "processing.source_changed"
    case inferenceModelNotFound = "inference.model_not_found"
    case inferenceUnsupportedModelArchitecture = "inference.unsupported_model_architecture"
    case inferenceMetalCompatibility = "inference.metal_compatibility"
    case inferenceWeightMappingFailed = "inference.weight_mapping_failed"
    case inferenceFailed = "inference.failed"
    case audioInvalidBuffer = "audio.invalid_buffer"
    case audioFileNotFound = "audio.file_not_found"
    case audioUnsupportedFormat = "audio.unsupported_format"
    case audioReadFailed = "audio.read_failed"
    case audioWriteFailed = "audio.write_failed"
    case playbackPreviewFileMissing = "playback.preview_file_missing"
    case unknownInspection = "unknown.inspection"
    case unknownPreparation = "unknown.preparation"
    case unknownProcessing = "unknown.processing"

    public static func classify(_ error: Error, category: DiagnosticFailureCategory) -> Self {
        if let error = error as? MediaIOError {
            return switch error {
            case .unsupportedContainer: .mediaUnsupportedContainer
            case .unreadable: .mediaUnreadable
            case .protectedContent: .mediaProtectedContent
            case .missingAudioTrack: .mediaMissingAudioTrack
            case .noSelectableAudioTrack: .mediaNoSelectableAudioTrack
            case .invalidAudioStreamSelection: .mediaInvalidAudioStreamSelection
            case .invalidAudioFormat: .mediaInvalidAudioFormat
            case .unsupportedChannelLayout: .mediaUnsupportedChannelLayout
            case .outputContainerMismatch: .mediaOutputContainerMismatch
            case .readerFailed: .mediaReaderFailed
            case .writerFailed: .mediaWriterFailed
            case .ffmpegUnavailable: .mediaFFmpegUnavailable
            case .ffmpegFailed: .mediaFFmpegFailed
            }
        }
        if let error = error as? MediaProcessingError {
            return switch error {
            case .emptyInput: .processingEmptyInput
            case .invalidInputLayout: .processingInvalidInputLayout
            case .inconsistentSessionBlockSize: .processingInconsistentSessionBlockSize
            case .inconsistentChannelOutput: .processingInconsistentChannelOutput
            case .invalidOutputPlan: .processingInvalidOutputPlan
            case .outputIdentityChanged: .processingOutputIdentityChanged
            case .destinationUnavailable: .processingDestinationUnavailable
            case .sourceUnavailable: .processingSourceUnavailable
            case .sourceChanged: .processingSourceChanged
            }
        }
        if let error = error as? InferenceError {
            return switch error {
            case .modelNotFound: .inferenceModelNotFound
            case .unsupportedModelArchitecture: .inferenceUnsupportedModelArchitecture
            case .metalInferenceIncompatible: .inferenceMetalCompatibility
            case .weightMappingFailed: .inferenceWeightMappingFailed
            case .inferenceFailed: .inferenceFailed
            }
        }
        if let error = error as? AudioIOError {
            return switch error {
            case .invalidBuffer: .audioInvalidBuffer
            case .fileNotFound: .audioFileNotFound
            case .unsupportedFormat: .audioUnsupportedFormat
            case .readFailed: .audioReadFailed
            case .writeFailed: .audioWriteFailed
            }
        }
        return switch category {
        case .inspection: .unknownInspection
        case .preparation: .unknownPreparation
        case .modelSetup: .modelSetupFailed
        case .modelUnavailable: .modelUnavailable
        case .modelLoad: .modelLoadFailed
        case .metalCompatibility: .metalCompatibility
        case .processing: .unknownProcessing
        }
    }
}

public struct DiagnosticFailure: Codable, Sendable, Equatable {
    public let category: DiagnosticFailureCategory
    public let code: DiagnosticFailureCode

    public init(category: DiagnosticFailureCategory, code: DiagnosticFailureCode) {
        self.category = category
        self.code = code
    }
}
