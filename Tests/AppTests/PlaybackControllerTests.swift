// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import App

@MainActor
final class PlaybackControllerTests: XCTestCase {
    func testWaveformLevelsHandleSilence() {
        XCTAssertEqual(
            PlaybackController.waveformLevels(for: [0, 0, 0, 0], binCount: 2),
            [0.08, 0.08]
        )
    }

    func testWaveformLevelsPreserveImpulsePeakAndBinLimit() {
        let levels = PlaybackController.waveformLevels(
            for: [0, 0, 1, 0, 0, 0],
            binCount: 3
        )
        XCTAssertEqual(levels.count, 3)
        XCTAssertEqual(levels.max(), 1)
    }

    func testWaveformLevelsHandleShortInput() {
        XCTAssertEqual(PlaybackController.waveformLevels(for: [0.5], binCount: 96), [1])
        XCTAssertEqual(PlaybackController.waveformLevels(for: [], binCount: 96), [])
        XCTAssertEqual(PlaybackController.waveformLevels(for: [1], binCount: 0), [])
    }

    func testPreparingFixtureInitializesEnhancedPreview() {
        let controller = PlaybackController()
        let fixture = projectRoot.appendingPathComponent(
            "Tests/Fixtures/Synthetic/sine_plus_noise_44100.wav"
        )

        controller.prepareComparison(inputURL: fixture, outputURL: fixture)

        XCTAssertNil(controller.issue)
        XCTAssertEqual(controller.selection, .enhanced)
        XCTAssertGreaterThan(controller.duration, 0)
        XCTAssertEqual(controller.progress, 0)
    }

    func testMissingPreviewIsNonfatal() {
        let controller = PlaybackController()
        let missing = projectRoot.appendingPathComponent("missing.wav")

        controller.prepareComparison(inputURL: missing, outputURL: missing)

        XCTAssertEqual(controller.issue, .previewFileMissing)
        XCTAssertEqual(controller.duration, 0)
        XCTAssertFalse(controller.isPlaying)
    }

    func testResetClearsPresentationState() {
        let controller = PlaybackController()
        controller.setOriginalSamples([0, 1])
        controller.setEnhancedSamples([0.5, 0.25])
        let fixture = projectRoot.appendingPathComponent(
            "Tests/Fixtures/Synthetic/sine_plus_noise_44100.wav"
        )
        controller.prepareComparison(inputURL: fixture, outputURL: fixture)

        controller.reset()

        XCTAssertEqual(controller.selection, .enhanced)
        XCTAssertFalse(controller.isPlaying)
        XCTAssertEqual(controller.progress, 0)
        XCTAssertEqual(controller.duration, 0)
        XCTAssertNil(controller.issue)
        XCTAssertEqual(controller.originalWaveformLevels, [])
        XCTAssertEqual(controller.enhancedWaveformLevels, [])
    }

    private var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
