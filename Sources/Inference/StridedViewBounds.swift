// SPDX-License-Identifier: Apache-2.0

import Foundation

/// The complete source-element range referenced by a manually constructed
/// strided view. `minimumIndex` and `maximumIndex` are nil when any dimension
/// is empty because such a view references no elements.
struct StridedViewBounds: Equatable, Sendable {
    let sourceElementCount: Int
    let shape: [Int]
    let strides: [Int]
    let offset: Int
    let minimumIndex: Int?
    let maximumIndex: Int?
    let requiredTrailingPadding: Int

    var isInBounds: Bool {
        guard let minimumIndex, let maximumIndex else { return true }
        return minimumIndex >= 0 && maximumIndex < sourceElementCount
    }

    static func calculate(
        sourceElementCount: Int,
        shape: [Int],
        strides: [Int],
        offset: Int = 0
    ) throws -> Self {
        guard sourceElementCount >= 0 else {
            throw StridedViewValidationError.invalidSourceElementCount(sourceElementCount)
        }
        guard shape.count == strides.count else {
            throw StridedViewValidationError.rankMismatch(shapeCount: shape.count, strideCount: strides.count)
        }
        guard !shape.contains(where: { $0 < 0 }) else {
            throw StridedViewValidationError.negativeDimension(shape)
        }

        if shape.contains(0) {
            return Self(
                sourceElementCount: sourceElementCount,
                shape: shape,
                strides: strides,
                offset: offset,
                minimumIndex: nil,
                maximumIndex: nil,
                requiredTrailingPadding: 0
            )
        }

        var minimumIndex = offset
        var maximumIndex = offset
        for (dimension, stride) in zip(shape, strides) {
            let (extent, extentOverflow) = (dimension - 1).multipliedReportingOverflow(by: stride)
            guard !extentOverflow else { throw StridedViewValidationError.arithmeticOverflow }

            if extent < 0 {
                let (updated, overflow) = minimumIndex.addingReportingOverflow(extent)
                guard !overflow else { throw StridedViewValidationError.arithmeticOverflow }
                minimumIndex = updated
            } else {
                let (updated, overflow) = maximumIndex.addingReportingOverflow(extent)
                guard !overflow else { throw StridedViewValidationError.arithmeticOverflow }
                maximumIndex = updated
            }
        }

        let requiredTrailingPadding: Int
        if maximumIndex >= sourceElementCount {
            let (shortfall, overflow) = maximumIndex.subtractingReportingOverflow(sourceElementCount - 1)
            guard !overflow else { throw StridedViewValidationError.arithmeticOverflow }
            requiredTrailingPadding = shortfall
        } else {
            requiredTrailingPadding = 0
        }

        return Self(
            sourceElementCount: sourceElementCount,
            shape: shape,
            strides: strides,
            offset: offset,
            minimumIndex: minimumIndex,
            maximumIndex: maximumIndex,
            requiredTrailingPadding: requiredTrailingPadding
        )
    }

    static func validate(
        sourceElementCount: Int,
        shape: [Int],
        strides: [Int],
        offset: Int = 0
    ) throws -> Self {
        let bounds = try calculate(
            sourceElementCount: sourceElementCount,
            shape: shape,
            strides: strides,
            offset: offset
        )
        guard bounds.isInBounds else {
            throw StridedViewValidationError.outOfBounds(bounds)
        }
        return bounds
    }
}

enum StridedViewValidationError: Error, Equatable, LocalizedError {
    case invalidSourceElementCount(Int)
    case rankMismatch(shapeCount: Int, strideCount: Int)
    case negativeDimension([Int])
    case arithmeticOverflow
    case outOfBounds(StridedViewBounds)

    var errorDescription: String? {
        switch self {
        case .invalidSourceElementCount(let count):
            return "Strided view source element count must be nonnegative; got \(count)"
        case .rankMismatch(let shapeCount, let strideCount):
            return "Strided view rank mismatch: shape has \(shapeCount) dimensions, strides has \(strideCount)"
        case .negativeDimension(let shape):
            return "Strided view shape contains a negative dimension: \(shape)"
        case .arithmeticOverflow:
            return "Strided view bounds calculation overflowed Int"
        case .outOfBounds(let bounds):
            let minimum = bounds.minimumIndex.map(String.init) ?? "none"
            let maximum = bounds.maximumIndex.map(String.init) ?? "none"
            return "Invalid strided view: sourceCount=\(bounds.sourceElementCount), "
                + "shape=\(bounds.shape), strides=\(bounds.strides), offset=\(bounds.offset), "
                + "minimumIndex=\(minimum), maximumIndex=\(maximum), "
                + "requiredAdditionalPadding=\(bounds.requiredTrailingPadding)"
        }
    }
}
