// SPDX-License-Identifier: Apache-2.0

/// Numerical execution mode for the fixed-16 selective scan.
public enum InferenceMode: String, Sendable, Equatable, Codable {
    /// The existing production arithmetic and Metal kernel.
    case standard
    /// The strict fast-bitcast-scalar selective-scan arithmetic.
    case strict
}
