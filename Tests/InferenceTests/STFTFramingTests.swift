// SPDX-License-Identifier: Apache-2.0

import MLX
import XCTest
@testable import Inference

final class STFTFramingTests: XCTestCase {
    func testExactFitSingleWindowNeedsNoDiscardedTail() throws {
        let plan = try CompleteFrameWindowPlan.make(sourceElementCount: 1_764, window: 1_764, hop: 222)
        XCTAssertEqual(plan, CompleteFrameWindowPlan(
            frameCount: 1,
            coveredSourceElementCount: 1_764,
            discardedTail: 0
        ))
        XCTAssertNoThrow(try StridedViewBounds.validate(
            sourceElementCount: 1_764,
            shape: [1, 1_764],
            strides: [222, 1]
        ))
    }

    func testExactFitMultipleWindowsNeedsNoPadding() throws {
        let plan = try CompleteFrameWindowPlan.make(sourceElementCount: 2_208, window: 1_764, hop: 222)
        XCTAssertEqual(plan.frameCount, 3)
        XCTAssertEqual(plan.coveredSourceElementCount, 2_208)
        XCTAssertEqual(plan.discardedTail, 0)
    }

    func testNonDivisibleRemainderDiscardsIncompleteFinalFrame() throws {
        let plan = try CompleteFrameWindowPlan.make(sourceElementCount: 2_209, window: 1_764, hop: 222)
        XCTAssertEqual(plan.frameCount, 3)
        XCTAssertEqual(plan.coveredSourceElementCount, 2_208)
        XCTAssertEqual(plan.discardedTail, 1)
    }

    func testCenteredFrameCountsMatchNVIDIAPyTorchFloorEnumeration() throws {
        let city = try CompleteFrameWindowPlan.make(
            sourceElementCount: 441_000 + 1_764,
            window: 1_764,
            hop: 220
        )
        XCTAssertEqual(city.frameCount, 2_005)
        XCTAssertEqual(city.discardedTail, 120)

        let edinburgh = try CompleteFrameWindowPlan.make(
            sourceElementCount: 37_454 + 1_920,
            window: 1_920,
            hop: 240
        )
        XCTAssertEqual(edinburgh.frameCount, 157)
        XCTAssertEqual(edinburgh.discardedTail, 14)
    }

    func testSourceShorterThanWindowHasNoCompleteFrames() throws {
        let plan = try CompleteFrameWindowPlan.make(sourceElementCount: 5, window: 8, hop: 3)
        XCTAssertEqual(plan.frameCount, 0)
        XCTAssertEqual(plan.coveredSourceElementCount, 0)
        XCTAssertEqual(plan.discardedTail, 5)
    }

    func testLengthsImmediatelyAroundWindowAndHopBoundaries() throws {
        let cases = [
            (source: 1_763, frames: 0, discardedTail: 1_763),
            (source: 1_764, frames: 1, discardedTail: 0),
            (source: 1_765, frames: 1, discardedTail: 1),
            (source: 1_985, frames: 1, discardedTail: 221),
            (source: 1_986, frames: 2, discardedTail: 0),
            (source: 1_987, frames: 2, discardedTail: 1),
        ]

        for item in cases {
            let plan = try CompleteFrameWindowPlan.make(
                sourceElementCount: item.source,
                window: 1_764,
                hop: 222
            )
            XCTAssertEqual(plan.frameCount, item.frames, "source=\(item.source)")
            XCTAssertEqual(plan.discardedTail, item.discardedTail, "source=\(item.source)")
        }
    }

    func testInvalidGeometryHasDedicatedError() {
        let cases = [
            (source: -1, window: 8, hop: 2),
            (source: 8, window: 0, hop: 2),
            (source: 8, window: 8, hop: 0),
        ]

        for item in cases {
            XCTAssertThrowsError(try CompleteFrameWindowPlan.make(
                sourceElementCount: item.source,
                window: item.window,
                hop: item.hop
            )) { error in
                XCTAssertEqual(
                    error as? STFTFramingError,
                    .invalidGeometry(
                        sourceElementCount: item.source,
                        window: item.window,
                        hop: item.hop
                    )
                )
            }
        }
    }

    func testMaximumFramingGeometryIsRepresentable() throws {
        let plan = try CompleteFrameWindowPlan.make(
            sourceElementCount: Int.max,
            window: 1,
            hop: 1
        )
        XCTAssertEqual(plan.frameCount, Int.max)
        XCTAssertEqual(plan.coveredSourceElementCount, Int.max)
        XCTAssertEqual(plan.discardedTail, 0)
    }

    func testMLXCompleteFramingDropsIncompleteTailAndIsRepeatable() throws {
        let sourceValues = (0..<45_864).map(Float.init)

        for _ in 0..<3 {
            let result = try MLXCompleteFrameFramer.frames(
                MLXArray(sourceValues),
                window: 1_764,
                hop: 222
            )
            MLX.eval(result.frames)

            XCTAssertEqual(result.frames.shape, [199, 1_764])
            XCTAssertEqual(result.plan.discardedTail, 144)
            let values = result.frames.asArray(Float.self)
            let finalFrame = Array(values.suffix(1_764))
            XCTAssertEqual(finalFrame, Array(sourceValues[43_956..<45_720]))
            XCTAssertTrue(values.allSatisfy(\.isFinite))
            XCTAssertNotEqual(values.reduce(0, +), 0)
        }
    }

    func testMLXExactFitFramingLeavesValuesUnchanged() throws {
        let sourceValues = (0..<2_208).map(Float.init)
        let result = try MLXCompleteFrameFramer.frames(
            MLXArray(sourceValues),
            window: 1_764,
            hop: 222
        )
        MLX.eval(result.frames)

        XCTAssertEqual(result.plan.discardedTail, 0)
        XCTAssertEqual(result.frames.shape, [3, 1_764])
        let values = result.frames.asArray(Float.self)
        XCTAssertEqual(Array(values.prefix(1_764)), Array(sourceValues[0..<1_764]))
        XCTAssertEqual(Array(values.suffix(1_764)), Array(sourceValues[444..<2_208]))
    }
}
