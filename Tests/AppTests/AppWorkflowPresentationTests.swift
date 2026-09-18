// SPDX-License-Identifier: Apache-2.0

import Foundation
import Processing
import XCTest
@testable import App

@MainActor
final class AppWorkflowPresentationTests: XCTestCase {
    func testProcessingLabelsCoverEveryCanonicalPhase() throws {
        let root = try makeTemporaryTestDirectory(prefix: "AppWorkflowPresentationTests")
        let fixture = try WorkflowMediaFixture.make(root: root)
        guard let preparedJob = fixture.preparedJobs[0] else {
            return XCTFail("Missing prepared workflow fixture")
        }
        let job = PendingMediaJob(
            inputURL: fixture.inputURL,
            outputURL: fixture.outputURL
        )
        let context = MediaJobContext(
            job: job,
            preparedJob: preparedJob,
            info: AppInspectedMedia(preparedJob: preparedJob)
        )

        XCTAssertEqual(
            label(phase: .preflight, context: context, completedWork: 1, totalWork: 4),
            "Enhancing speech... 25%"
        )
        XCTAssertEqual(
            label(phase: .enhancing, context: context, completedWork: 1, totalWork: 2),
            "Enhancing speech... 50%"
        )
        XCTAssertEqual(
            label(phase: .validating, context: context),
            "Validating output..."
        )
        XCTAssertEqual(
            label(phase: .finalizing, context: context),
            "Finalizing media..."
        )
        XCTAssertEqual(
            label(phase: .committing, context: context),
            "Publishing output..."
        )
    }

    func testCompletedLabelCallsOutWarnings() throws {
        let root = try makeTemporaryTestDirectory(
            prefix: "AppWorkflowCompletedWarnings"
        )
        let fixture = try WorkflowMediaFixture.make(root: root)
        let preparedJob = try XCTUnwrap(fixture.preparedJobs[0])
        let context = MediaJobContext(
            job: PendingMediaJob(
                inputURL: fixture.inputURL,
                outputURL: fixture.outputURL
            ),
            preparedJob: preparedJob,
            info: AppInspectedMedia(preparedJob: preparedJob),
            notices: [.auxiliaryStreamsOmitted(streamIndices: [7])]
        )

        XCTAssertTrue(context.hasWarnings)
        let completedLabel = try XCTUnwrap(
            AppWorkflowPresentation.stageLabel(for: .completed(context))
        )
        XCTAssertEqual(
            localized(completedLabel, locale: Locale(identifier: "en")),
            "Enhanced audio is ready. See warnings."
        )
    }

    private func label(
        phase: MediaProcessingPhase,
        context: MediaJobContext,
        completedWork: Int64 = 1,
        totalWork: Int64 = 1
    ) -> String? {
        AppWorkflowPresentation.stageLabel(for: .processing(
            context,
            MediaProcessingProgress(
                phase: phase,
                completedWork: completedWork,
                totalWork: totalWork
            )
        )).map { localized($0, locale: Locale(identifier: "en")) }
    }
}
