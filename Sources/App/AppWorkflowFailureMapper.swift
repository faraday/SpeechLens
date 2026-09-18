// SPDX-License-Identifier: Apache-2.0

import AudioIO
import Diagnostics
import Foundation
import Inference

enum AppWorkflowFailurePhase {
    case inspection
    case preparation
    case processing
}

enum AppWorkflowFailureMapper {
    static func failure(
        for error: Error,
        phase: AppWorkflowFailurePhase,
        job: PendingMediaJob?,
        info: AudioFileInfo?
    ) -> AppWorkflowFailure {
        if let serviceError = error as? AudioEnhancementServiceError {
            switch serviceError {
            case .pipelineInitializationFailed(let inferenceError):
                let category: DiagnosticFailureCategory
                let code: DiagnosticFailureCode
                switch inferenceError {
                case .metalInferenceIncompatible:
                    category = .metalCompatibility
                    code = .metalCompatibility
                case .inferenceFailed:
                    category = .modelLoad
                    code = .modelLoadFailed
                default:
                    category = .modelLoad
                    code = DiagnosticFailureCode.classify(inferenceError, category: category)
                }
                return AppWorkflowFailure(
                    category: category,
                    code: code,
                    technicalDetail: inferenceError.localizedDescription,
                    job: job,
                    info: info
                )
            case .unexpectedPipelineInitializationFailure(let detail):
                return AppWorkflowFailure(
                    category: .modelLoad,
                    code: .modelLoadFailed,
                    technicalDetail: detail,
                    job: job,
                    info: info
                )
            }
        }

        let category: DiagnosticFailureCategory
        switch phase {
        case .inspection: category = .inspection
        case .preparation: category = .preparation
        case .processing: category = .processing
        }
        return AppWorkflowFailure(
            category: category,
            code: DiagnosticFailureCode.classify(error, category: category),
            technicalDetail: technicalDescription(of: error),
            job: job,
            info: info
        )
    }

    private static func technicalDescription(of error: Error) -> String {
        if let error = error as? InferenceError { return String(describing: error) }
        if let error = error as? AudioIOError { return String(describing: error) }
        return error.localizedDescription
    }
}
