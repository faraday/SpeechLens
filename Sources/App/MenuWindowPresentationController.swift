// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine

enum MenuWindowLayout {
    static let width: CGFloat = 420
    static let minimumHeight: CGFloat = 240
    static let preferredMaxHeight: CGFloat = 620
    static let screenEdgePadding: CGFloat = 72
    static let footerHeight: CGFloat = 45
}

struct LaunchMenuPresentation: Equatable {
    let shouldShow: Bool

    init(onboardingIsRequired: Bool, modelIsReady: Bool) {
        shouldShow = onboardingIsRequired || !modelIsReady
    }
}

@MainActor
final class MenuWindowPresentationController: ObservableObject {
    private enum ExpandedDisclosure {
        case advanced
        case privacy
        case about
    }

    @Published private var expandedDisclosure: ExpandedDisclosure?
    @Published private(set) var height: CGFloat = MenuWindowLayout.minimumHeight
    @Published private(set) var maximumHeight: CGFloat = MenuWindowLayout.preferredMaxHeight

    var isPrivacyExpanded: Bool { expandedDisclosure == .privacy }
    var isAboutExpanded: Bool { expandedDisclosure == .about }
    var isAdvancedExpanded: Bool { expandedDisclosure == .advanced }

    var closePopover: (() -> Void)?
    var resizePopover: ((CGFloat) -> Void)?

    private var measuredContentHeight = MenuWindowLayout.minimumHeight

    func requestClose() {
        closePopover?()
    }

    func updateAvailableHeight(_ visibleHeight: CGFloat) {
        maximumHeight = min(
            MenuWindowLayout.preferredMaxHeight,
            max(MenuWindowLayout.minimumHeight, visibleHeight - MenuWindowLayout.screenEdgePadding)
        )
        applyMeasuredHeight()
    }

    func requestContentHeight(_ contentHeight: CGFloat) {
        measuredContentHeight = max(contentHeight, MenuWindowLayout.minimumHeight)
        applyMeasuredHeight()
    }

    func togglePrivacyDisclosure() {
        toggleDisclosure(.privacy)
    }

    func toggleAdvancedDisclosure() {
        toggleDisclosure(.advanced)
    }

    func toggleAboutDisclosure() {
        toggleDisclosure(.about)
    }

    func resetDisclosureState() {
        expandedDisclosure = nil
    }

    private func toggleDisclosure(_ disclosure: ExpandedDisclosure) {
        expandedDisclosure = expandedDisclosure == disclosure ? nil : disclosure
    }

    private func applyMeasuredHeight() {
        let resolved = min(
            max(ceil(measuredContentHeight), MenuWindowLayout.minimumHeight),
            maximumHeight
        )
        guard abs(height - resolved) > 0.5 else { return }
        height = resolved
        resizePopover?(resolved)
    }
}
