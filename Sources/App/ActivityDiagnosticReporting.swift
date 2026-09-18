// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation

struct DailyActivityRecord: Sendable, Equatable {
    static let schemaVersion = 1
    static let effectiveTelemetrySampleRate = 1.0
    static let allowedDimensionNames: Set<String> = [
        "event_schema_version",
        "app_version",
        "app_build",
        "macos_version",
        "hardware_model",
        "effective_telemetry_sample_rate",
    ]

    let dimensions: [String: String]

    init?(environment: DiagnosticEnvironment) {
        let values = [
            "event_schema_version": String(Self.schemaVersion),
            "app_version": environment.appVersion,
            "app_build": environment.appBuild,
            "macos_version": environment.macOSVersion,
            "hardware_model": environment.hardwareModel,
            "effective_telemetry_sample_rate": String(
                Self.effectiveTelemetrySampleRate
            ),
        ]
        guard values.values.allSatisfy(isSafeActivityDiagnosticDimension)
        else { return nil }
        dimensions = values
    }
}

private func isSafeActivityDiagnosticDimension(_ value: String) -> Bool {
    !value.isEmpty
        && value.utf8.count <= 128
        && !value.contains("/")
        && !value.contains("\\")
        && !value.contains("\n")
        && !value.contains("\r")
        && !value.contains("://")
}
