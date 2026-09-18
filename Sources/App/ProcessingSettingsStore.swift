// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference

@MainActor
final class ProcessingSettingsStore {
    private static let profileKey = "processingProfile"
    private static let customSettingsKey = "customProcessingSettings"
    private static let inferenceModeKey = "inferenceMode"

    private let defaults: UserDefaults
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(
        defaults: UserDefaults = .standard,
        encoder: JSONEncoder = JSONEncoder(),
        decoder: JSONDecoder = JSONDecoder()
    ) {
        self.defaults = defaults
        self.encoder = encoder
        self.decoder = decoder
    }

    func loadProfile() -> ProcessingProfile {
        guard let rawValue = defaults.string(forKey: Self.profileKey),
              let profile = ProcessingProfile(rawValue: rawValue) else {
            return .fast
        }
        return profile
    }

    func loadCustomSettings() -> InferenceSettings? {
        guard let data = defaults.data(forKey: Self.customSettingsKey) else { return nil }
        return try? decoder.decode(InferenceSettings.self, from: data)
    }

    func saveProfile(_ profile: ProcessingProfile) {
        defaults.set(profile.rawValue, forKey: Self.profileKey)
    }

    func saveCustomSettings(_ settings: InferenceSettings) {
        guard let data = try? encoder.encode(settings) else { return }
        defaults.set(data, forKey: Self.customSettingsKey)
    }

    func loadInferenceMode() -> InferenceMode {
        guard let rawValue = defaults.string(forKey: Self.inferenceModeKey),
              let mode = InferenceMode(rawValue: rawValue) else {
            return .standard
        }
        return mode
    }

    func saveInferenceMode(_ mode: InferenceMode) {
        defaults.set(mode.rawValue, forKey: Self.inferenceModeKey)
    }
}
