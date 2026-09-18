// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation

enum AppFailurePresentation {
    static func message(
        for failure: AppWorkflowFailure
    ) -> LocalizedStringResource {
        message(for: failure.code)
    }

    static func message(
        for code: DiagnosticFailureCode
    ) -> LocalizedStringResource {
        switch code {
        case .modelUnavailable: .failureModelUnavailable
        case .modelSetupFailed: .failureModelSetupFailed
        case .modelCacheManifestMissing: .failureModelCacheManifestMissing
        case .modelCacheManifestMismatch: .failureModelCacheManifestMismatch
        case .modelCacheChecksumMismatch: .failureModelCacheChecksumMismatch
        case .modelCacheVerificationFailed: .failureModelCacheVerificationFailed
        case .modelDownloadInvalidManifest: .failureModelDownloadInvalidManifest
        case .modelDownloadMissingChecksum: .failureModelDownloadMissingChecksum
        case .modelDownloadManifestMismatch: .failureModelDownloadManifestMismatch
        case .modelDownloadChecksumMismatch: .failureModelDownloadChecksumMismatch
        case .modelDownloadMissingFile: .failureModelDownloadMissingFile
        case .modelDownloadHTTPStatus: .failureModelDownloadHttpStatus
        case .modelDownloadNetwork: .failureModelDownloadNetwork
        case .modelDownloadInstallation: .failureModelDownloadInstallation
        case .modelLoadFailed: .failureModelLoadFailed
        case .metalCompatibility: .failureModelMetalCompatibility
        case .mediaUnsupportedContainer: .failureMediaUnsupportedContainer
        case .mediaUnreadable: .failureMediaUnreadable
        case .mediaProtectedContent: .failureMediaProtectedContent
        case .mediaMissingAudioTrack: .failureMediaMissingAudioTrack
        case .mediaNoSelectableAudioTrack: .failureMediaNoSelectableAudioTrack
        case .mediaInvalidAudioStreamSelection:
            .failureMediaInvalidAudioStreamSelection
        case .mediaInvalidAudioFormat: .failureMediaInvalidAudioFormat
        case .mediaUnsupportedChannelLayout: .failureMediaUnsupportedChannelLayout
        case .mediaOutputContainerMismatch: .failureMediaOutputContainerMismatch
        case .mediaReaderFailed: .failureMediaReaderFailed
        case .mediaWriterFailed: .failureMediaWriterFailed
        case .mediaFFmpegUnavailable: .failureMediaFfmpegUnavailable
        case .mediaFFmpegFailed: .failureMediaFfmpegFailed
        case .processingEmptyInput: .failureProcessingEmptyInput
        case .processingInvalidInputLayout: .failureProcessingInvalidInputLayout
        case .processingInconsistentSessionBlockSize:
            .failureProcessingInconsistentSessionBlockSize
        case .processingInconsistentChannelOutput:
            .failureProcessingInconsistentChannelOutput
        case .processingInvalidOutputPlan: .failureProcessingInvalidOutputPlan
        case .processingOutputIdentityChanged: .failureProcessingOutputIdentityChanged
        case .processingDestinationUnavailable:
            .failureProcessingDestinationUnavailable
        case .processingSourceUnavailable: .failureProcessingSourceUnavailable
        case .processingSourceChanged: .failureProcessingSourceChanged
        case .inferenceModelNotFound: .failureInferenceModelNotFound
        case .inferenceUnsupportedModelArchitecture:
            .failureInferenceUnsupportedModelArchitecture
        case .inferenceMetalCompatibility: .failureInferenceMetalCompatibility
        case .inferenceWeightMappingFailed: .failureInferenceWeightMappingFailed
        case .inferenceFailed: .failureInferenceFailed
        case .audioInvalidBuffer: .failureAudioInvalidBuffer
        case .audioFileNotFound: .failureAudioFileNotFound
        case .audioUnsupportedFormat: .failureAudioUnsupportedFormat
        case .audioReadFailed: .failureAudioReadFailed
        case .audioWriteFailed: .failureAudioWriteFailed
        case .playbackPreviewFileMissing: .failurePlaybackPreviewFileMissing
        case .unknownInspection: .failureUnknownInspection
        case .unknownPreparation: .failureUnknownPreparation
        case .unknownProcessing: .failureUnknownProcessing
        }
    }

    static func localizationKey(
        for code: DiagnosticFailureCode
    ) -> String {
        "failure.\(code.rawValue)"
    }
}
