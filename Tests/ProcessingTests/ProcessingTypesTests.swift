// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Processing

final class ProcessingTypesTests: XCTestCase {
    func testTimingBoundariesProduceExactContiguousPartition() {
        let start = ContinuousClock.now
        let boundaries = MediaProcessingTimingBoundaries(
            pipelineStart: start,
            passStart: start.advanced(by: .seconds(2)),
            finalizingStart: start.advanced(by: .seconds(7)),
            validationStart: start.advanced(by: .seconds(8)),
            commitStart: start.advanced(by: .seconds(11)),
            pipelineEnd: start.advanced(by: .seconds(13))
        )

        let timings = boundaries.timings

        XCTAssertEqual(timings.preflight, .seconds(2))
        XCTAssertEqual(timings.enhancing, .seconds(5))
        XCTAssertEqual(timings.finalizing, .seconds(1))
        XCTAssertEqual(timings.enhancementPass, .seconds(6))
        XCTAssertEqual(timings.validating, .seconds(3))
        XCTAssertEqual(timings.committing, .seconds(2))
        XCTAssertEqual(timings.total, .seconds(13))
        XCTAssertTrue(timings.isConsistent)
    }

    func testTimingConsistencyRejectsNegativeAndMismatchedValues() {
        let negative = MediaProcessingTimings(
            total: .zero,
            preflight: .seconds(-1),
            enhancing: .zero,
            finalizing: .zero,
            validating: .zero,
            committing: .zero,
            enhancementPass: .zero,
            channelEnhancementPasses: []
        )
        let mismatched = MediaProcessingTimings(
            total: .seconds(5),
            preflight: .seconds(1),
            enhancing: .seconds(1),
            finalizing: .seconds(1),
            validating: .seconds(1),
            committing: .seconds(1),
            enhancementPass: .seconds(3),
            channelEnhancementPasses: []
        )

        XCTAssertFalse(negative.isConsistent)
        XCTAssertFalse(mismatched.isConsistent)
    }

    func testTimingConsistencyRejectsNegativeChannelEnhancementPass() {
        let timings = MediaProcessingTimings(
            total: .seconds(5),
            preflight: .seconds(1),
            enhancing: .seconds(1),
            finalizing: .seconds(1),
            validating: .seconds(1),
            committing: .seconds(1),
            enhancementPass: .seconds(2),
            channelEnhancementPasses: [.seconds(-1)]
        )

        XCTAssertFalse(timings.isConsistent)
    }

    func testProgressFractionUsesCompletedWorkAndClampsToUnitRange() {
        XCTAssertEqual(
            MediaProcessingProgress(
                phase: .enhancing,
                completedWork: 25,
                totalWork: 100
            ).fractionCompleted,
            0.25
        )
        XCTAssertEqual(
            MediaProcessingProgress(
                phase: .enhancing,
                completedWork: -1,
                totalWork: 100
            ).fractionCompleted,
            0
        )
        XCTAssertEqual(
            MediaProcessingProgress(
                phase: .enhancing,
                completedWork: 101,
                totalWork: 100
            ).fractionCompleted,
            1
        )
    }

    func testZeroTotalWorkIsCompleteOnlyWhenCommitting() {
        for phase in [
            MediaProcessingPhase.preflight,
            .enhancing,
            .validating,
        ] {
            XCTAssertEqual(
                MediaProcessingProgress(
                    phase: phase,
                    completedWork: 0,
                    totalWork: 0
                ).fractionCompleted,
                0
            )
        }
        XCTAssertEqual(
            MediaProcessingProgress(
                phase: .committing,
                completedWork: 0,
                totalWork: 0
            ).fractionCompleted,
            1
        )
    }
}
