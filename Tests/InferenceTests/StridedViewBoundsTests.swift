// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Inference

final class StridedViewBoundsTests: XCTestCase {
    func testHistoricalViewIsSeventyEightElementsShort() throws {
        let bounds = try StridedViewBounds.calculate(
            sourceElementCount: 45_864,
            shape: [200, 1_764],
            strides: [222, 1]
        )
        XCTAssertEqual(bounds.minimumIndex, 0)
        XCTAssertEqual(bounds.maximumIndex, 45_941)
        XCTAssertEqual(bounds.requiredTrailingPadding, 78)
        XCTAssertFalse(bounds.isInBounds)

        XCTAssertThrowsError(try StridedViewBounds.validate(
            sourceElementCount: 45_864,
            shape: [200, 1_764],
            strides: [222, 1]
        )) { error in
            guard case .outOfBounds(let rejected) = error as? StridedViewValidationError else {
                return XCTFail("Expected out-of-bounds error, got \(error)")
            }
            XCTAssertEqual(rejected.requiredTrailingPadding, 78)
            XCTAssertTrue(error.localizedDescription.contains("sourceCount=45864"))
            XCTAssertTrue(error.localizedDescription.contains("maximumIndex=45941"))
            XCTAssertTrue(error.localizedDescription.contains("requiredAdditionalPadding=78"))
        }
    }

    func testHistoricalPaddedViewIsAccepted() {
        XCTAssertNoThrow(try StridedViewBounds.validate(
            sourceElementCount: 45_942,
            shape: [200, 1_764],
            strides: [222, 1]
        ))
    }

    func testHistoricalDropLastViewWouldAlsoBeAccepted() {
        XCTAssertNoThrow(try StridedViewBounds.validate(
            sourceElementCount: 45_864,
            shape: [199, 1_764],
            strides: [222, 1]
        ))
    }

    func testPositiveAndNegativeStridesWithNonzeroOffsets() throws {
        let positive = try StridedViewBounds.validate(
            sourceElementCount: 12,
            shape: [3, 4],
            strides: [4, 1]
        )
        XCTAssertEqual(positive.minimumIndex, 0)
        XCTAssertEqual(positive.maximumIndex, 11)

        let negative = try StridedViewBounds.validate(
            sourceElementCount: 12,
            shape: [3, 4],
            strides: [-4, -1],
            offset: 11
        )
        XCTAssertEqual(negative.minimumIndex, 0)
        XCTAssertEqual(negative.maximumIndex, 11)

        let offset = try StridedViewBounds.validate(
            sourceElementCount: 20,
            shape: [2, 3],
            strides: [5, 1],
            offset: 4
        )
        XCTAssertEqual(offset.minimumIndex, 4)
        XCTAssertEqual(offset.maximumIndex, 11)
    }

    func testRejectsViewExceedingSourceByOneElement() {
        XCTAssertThrowsError(try StridedViewBounds.validate(
            sourceElementCount: 11,
            shape: [3, 4],
            strides: [4, 1]
        )) { error in
            guard case .outOfBounds(let bounds) = error as? StridedViewValidationError else {
                return XCTFail("Expected out-of-bounds error, got \(error)")
            }
            XCTAssertEqual(bounds.maximumIndex, 11)
            XCTAssertEqual(bounds.requiredTrailingPadding, 1)
        }
    }

    func testEmptyDimensionReferencesNoElements() throws {
        let bounds = try StridedViewBounds.validate(
            sourceElementCount: 0,
            shape: [2, 0, 4],
            strides: [100, Int.max, -7],
            offset: Int.max
        )
        XCTAssertNil(bounds.minimumIndex)
        XCTAssertNil(bounds.maximumIndex)
        XCTAssertEqual(bounds.requiredTrailingPadding, 0)
    }

    func testCheckedExtentArithmeticOverflowIsRejected() {
        XCTAssertThrowsError(try StridedViewBounds.calculate(
            sourceElementCount: Int.max,
            shape: [Int.max],
            strides: [2]
        )) { error in
            XCTAssertEqual(error as? StridedViewValidationError, .arithmeticOverflow)
        }
    }

    func testCheckedPaddingShortfallOverflowIsRejected() {
        XCTAssertThrowsError(try StridedViewBounds.calculate(
            sourceElementCount: 0,
            shape: [1],
            strides: [0],
            offset: Int.max
        )) { error in
            XCTAssertEqual(error as? StridedViewValidationError, .arithmeticOverflow)
        }
    }
}
