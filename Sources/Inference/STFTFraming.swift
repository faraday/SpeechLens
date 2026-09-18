// SPDX-License-Identifier: Apache-2.0

import Foundation
import MLX

enum STFTFramingError: Error, Equatable, LocalizedError {
    case invalidGeometry(sourceElementCount: Int, window: Int, hop: Int)
    case arithmeticOverflow

    var errorDescription: String? {
        switch self {
        case .invalidGeometry(let sourceElementCount, let window, let hop):
            return "Invalid STFT framing geometry: sourceCount=\(sourceElementCount), "
                + "window=\(window), hop=\(hop); sourceCount must be nonnegative "
                + "and window and hop must be positive"
        case .arithmeticOverflow:
            return "STFT framing geometry calculation overflowed Int"
        }
    }
}

/// Geometry for PyTorch-compatible complete STFT frames.
///
/// PyTorch's centered `torch.stft` enumerates only complete analysis windows:
/// an incomplete final hop is discarded rather than zero-padded. Center
/// padding is applied by the caller before this plan is constructed.
struct CompleteFrameWindowPlan: Equatable, Sendable {
    let frameCount: Int
    let coveredSourceElementCount: Int
    let discardedTail: Int

    static func make(sourceElementCount: Int, window: Int, hop: Int) throws -> Self {
        guard sourceElementCount >= 0, window > 0, hop > 0 else {
            throw STFTFramingError.invalidGeometry(
                sourceElementCount: sourceElementCount,
                window: window,
                hop: hop
            )
        }

        guard sourceElementCount >= window else {
            return Self(
                frameCount: 0,
                coveredSourceElementCount: 0,
                discardedTail: sourceElementCount
            )
        }

        let distance = sourceElementCount - window
        let quotient = distance / hop
        let (frameCount, frameOverflow) = quotient.addingReportingOverflow(1)
        guard !frameOverflow else { throw STFTFramingError.arithmeticOverflow }

        let (lastStart, startOverflow) = (frameCount - 1).multipliedReportingOverflow(by: hop)
        guard !startOverflow else { throw STFTFramingError.arithmeticOverflow }
        let (coveredCount, countOverflow) = lastStart.addingReportingOverflow(window)
        guard !countOverflow else { throw STFTFramingError.arithmeticOverflow }

        return Self(
            frameCount: frameCount,
            coveredSourceElementCount: coveredCount,
            discardedTail: max(0, sourceElementCount - coveredCount)
        )
    }
}

/// Constructs the project's only manual MLX strided view from complete frames.
/// Center padding is performed by the STFT caller; samples in an incomplete
/// final hop are intentionally excluded to match PyTorch's floor enumeration.
enum MLXCompleteFrameFramer {
    static func frames(
        _ source: MLXArray,
        window: Int,
        hop: Int,
        stream: StreamOrDevice = .default
    ) throws -> (frames: MLXArray, plan: CompleteFrameWindowPlan) {
        let plan = try CompleteFrameWindowPlan.make(
            sourceElementCount: source.size,
            window: window,
            hop: hop
        )
        let shape = [plan.frameCount, window]
        let strides = [hop, 1]
        _ = try StridedViewBounds.validate(
            sourceElementCount: source.size,
            shape: shape,
            strides: strides
        )
        return (
            asStrided(source, shape, strides: strides, stream: stream),
            plan
        )
    }
}
