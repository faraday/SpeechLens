// SPDX-License-Identifier: Apache-2.0

import Foundation

enum AppWorkflowPresentation {
    static func stageLabel(
        for state: AppWorkflowState
    ) -> LocalizedStringResource? {
        switch state {
        case .idle:
            return nil
        case .preparing:
            return LocalizedStringResource.workflowStatusInspecting
        case .loadingModel:
            return LocalizedStringResource.workflowStatusLoadingModel
        case .processing(_, let progress):
            switch progress.phase {
            case .preflight, .enhancing:
                let percentage = Int((progress.fractionCompleted * 100).rounded(.down))
                return .workflowStatusEnhancingProgress(percentage)
            case .finalizing:
                return LocalizedStringResource.workflowStatusFinalizing
            case .validating:
                return LocalizedStringResource.workflowStatusValidating
            case .committing:
                return LocalizedStringResource.workflowStatusCommitting
            }
        case .completed(let context):
            return context.hasWarnings
                ? .workflowStatusCompletedWithWarnings
                : .workflowStatusCompleted
        case .selectingAudioTrack:
            return nil
        case .cancelled:
            return LocalizedStringResource.workflowStatusCancelled
        case .failed(let failure):
            return AppFailurePresentation.message(for: failure)
        }
    }
}
