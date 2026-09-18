// SPDX-License-Identifier: Apache-2.0

import AppKit
import XCTest
@testable import App

@MainActor
final class MenuWindowPresentationControllerTests: XCTestCase {
    func testMenuPopoverRetainsFinderFocusForDragAndDrop() {
        XCTAssertEqual(
            MenuBarPopoverCoordinator.popoverBehavior,
            .applicationDefined
        )
    }

    func testMenuBarIconAssetLoadsAsTemplate() {
        let image = NSImage(named: "MenuBarIcon")
        XCTAssertNotNil(image, "MenuBarIcon.pdf must be in the app asset catalog")
        XCTAssertEqual(image?.isTemplate, true)
    }

    func testRequiredOnboardingShowsPopover() {
        let presentation = LaunchMenuPresentation(
            onboardingIsRequired: true,
            modelIsReady: true
        )

        XCTAssertTrue(presentation.shouldShow)
    }

    func testReturningLaunchSkipsPopoverWhenModelIsReady() {
        let presentation = LaunchMenuPresentation(
            onboardingIsRequired: false,
            modelIsReady: true
        )

        XCTAssertFalse(presentation.shouldShow)
    }

    func testReturningLaunchShowsPopoverWhenModelIsMissing() {
        let presentation = LaunchMenuPresentation(
            onboardingIsRequired: false,
            modelIsReady: false
        )

        XCTAssertTrue(presentation.shouldShow)
    }

    func testContentHeightIsBounded() {
        let controller = MenuWindowPresentationController()
        controller.requestContentHeight(800)

        XCTAssertEqual(controller.height, 620)
    }

    func testDisclosureInteractionsAreMutuallyExclusive() {
        let controller = MenuWindowPresentationController()
        controller.togglePrivacyDisclosure()
        controller.toggleAboutDisclosure()

        XCTAssertFalse(controller.isPrivacyExpanded)
        XCTAssertTrue(controller.isAboutExpanded)
    }

    func testAdvancedDisclosureIsMutuallyExclusiveAndCanCollapse() {
        let controller = MenuWindowPresentationController()
        controller.toggleAdvancedDisclosure()
        XCTAssertTrue(controller.isAdvancedExpanded)
        XCTAssertFalse(controller.isPrivacyExpanded)
        XCTAssertFalse(controller.isAboutExpanded)

        controller.togglePrivacyDisclosure()
        XCTAssertFalse(controller.isAdvancedExpanded)
        XCTAssertTrue(controller.isPrivacyExpanded)

        controller.toggleAdvancedDisclosure()
        controller.toggleAdvancedDisclosure()
        XCTAssertFalse(controller.isAdvancedExpanded)
    }

    func testResetClearsPresentationDisclosureState() {
        let controller = MenuWindowPresentationController()
        controller.toggleAboutDisclosure()
        controller.toggleAdvancedDisclosure()
        controller.resetDisclosureState()

        XCTAssertFalse(controller.isPrivacyExpanded)
        XCTAssertFalse(controller.isAboutExpanded)
        XCTAssertFalse(controller.isAdvancedExpanded)
    }
}
