// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Owns the AppKit behavior that SwiftUI's menu-bar scenes cannot express.
///
/// An application-defined popover stays open while the user activates Finder
/// and drags a file into SpeechLens. The status item and the in-content close
/// button remain the only user-facing ways to dismiss it.
@MainActor
final class MenuBarPopoverCoordinator: NSObject {
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    private let appState: AppState
    private let presentation: MenuWindowPresentationController
    private let recordActivity: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var isInstalled = false

    init(
        appState: AppState,
        presentation: MenuWindowPresentationController,
        recordActivity: @escaping @MainActor () -> Void = {}
    ) {
        self.appState = appState
        self.presentation = presentation
        self.recordActivity = recordActivity
        statusItem = NSStatusBar.system.statusItem(
            withLength: NSStatusItem.variableLength
        )
        popover = NSPopover()
        super.init()
    }

    func install() {
        guard !isInstalled else { return }
        isInstalled = true

        presentation.closePopover = { [weak self] in
            self?.close()
        }
        presentation.resizePopover = { [weak self] height in
            self?.popover.contentSize = NSSize(
                width: MenuWindowLayout.width,
                height: height
            )
        }

        if let button = statusItem.button {
            button.image = Self.makeMenuBarImage()
            button.target = self
            button.action = #selector(toggle(_:))
        }

        popover.behavior = Self.popoverBehavior
        popover.contentSize = NSSize(
            width: MenuWindowLayout.width,
            height: presentation.height
        )
        popover.contentViewController = NSHostingController(
            rootView: MenuContentView()
                .environmentObject(appState)
                .environmentObject(appState.modelStore)
                .environmentObject(appState.playback)
                .environmentObject(presentation)
        )
    }

    func show() {
        guard let button = statusItem.button else { return }
        recordActivity()
        updateHeightLimit(for: button)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
    }

    func close() {
        guard popover.isShown else { return }
        presentation.resetDisclosureState()
        appState.playback.stop(resetPosition: false)
        popover.performClose(nil)
    }

    @objc private func toggle(_ sender: AnyObject?) {
        if popover.isShown {
            close()
        } else {
            show()
        }
    }

    private func updateHeightLimit(for button: NSStatusBarButton) {
        let visibleHeight = button.window?.screen?.visibleFrame.height
            ?? NSScreen.main?.visibleFrame.height
            ?? MenuWindowLayout.preferredMaxHeight
        presentation.updateAvailableHeight(visibleHeight)
    }

    /// Template gapped-lens mark; falls back to the prior SF Symbol if the
    /// asset catalog image is missing from the bundle.
    private static func makeMenuBarImage() -> NSImage {
        let accessibilityName = localized(.appName)
        if let catalog = NSImage(named: "MenuBarIcon") {
            let image = catalog.copy() as? NSImage ?? catalog
            image.isTemplate = true
            image.size = NSSize(width: 18, height: 18)
            image.accessibilityDescription = accessibilityName
            return image
        }
        return NSImage(
            systemSymbolName: "waveform.badge.mic",
            accessibilityDescription: accessibilityName
        ) ?? NSImage()
    }
}
