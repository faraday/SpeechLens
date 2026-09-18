// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference

enum ProcessingProfile: String, CaseIterable, Identifiable, Sendable {
    case fast
    case balanced
    case extended
    case custom

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .fast: LocalizedStringResource.profileTitleFast
        case .balanced: LocalizedStringResource.profileTitleBalanced
        case .extended: LocalizedStringResource.profileTitleExtended
        case .custom: LocalizedStringResource.profileTitleCustom
        }
    }

    var detail: LocalizedStringResource {
        switch self {
        case .fast:
            LocalizedStringResource.profileDetailFast
        case .balanced:
            LocalizedStringResource.profileDetailBalanced
        case .extended:
            LocalizedStringResource.profileDetailExtended
        case .custom:
            LocalizedStringResource.profileDetailCustom
        }
    }

    var presetSettings: InferenceSettings? {
        switch self {
        case .fast:
            .standard
        case .balanced:
            try? InferenceSettings(chunkSeconds: 10, overlapPortion: 0.05)
        case .extended:
            try? InferenceSettings(chunkSeconds: 30, overlapPortion: 0.05)
        case .custom:
            nil
        }
    }
}
