// SPDX-License-Identifier: Apache-2.0

import Foundation
import XCTest
@testable import App

@MainActor
final class MetalInferenceCompatibilityTests: XCTestCase {
    func testMetalCompatibilityFailureUsesActionableWorkflowMessage() {
        let failure = AppWorkflowFailureMapper.failure(
            for: AudioEnhancementServiceError.pipelineInitializationFailed(
                .metalInferenceIncompatible(
                    "A_log has an unsupported state size"
                )
            ),
            phase: .processing,
            job: nil,
            info: nil
        )
        let message = localized(
            AppFailurePresentation.message(for: failure),
            locale: Locale(identifier: "en")
        )
        let expected = localized(
            AppFailurePresentation.message(for: .metalCompatibility),
            locale: Locale(identifier: "en")
        )

        XCTAssertEqual(message, expected)
        XCTAssertTrue(message.contains("Update or re-download"))
        XCTAssertFalse(message.contains("A_log"))
    }
}
