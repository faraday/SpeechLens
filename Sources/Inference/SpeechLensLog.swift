// SPDX-License-Identifier: Apache-2.0

import OSLog

enum SpeechLensLog {
    private static let subsystem = "dev.speechlens.SpeechLens"

    static let inference = Logger(subsystem: subsystem, category: "Inference")
    static let mamba = Logger(subsystem: subsystem, category: "Mamba")
}
