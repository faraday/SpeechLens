// SPDX-License-Identifier: Apache-2.0

import AppKit
import Combine
import SwiftUI

/// Owns the AppKit behavior that SwiftUI's menu-bar scenes cannot express.
///
/// An application-defined popover stays open while the user activates Finder
/// and drags a file into SpeechLens. It temporarily yields to the file picker.
@MainActor
final class MenuBarPopoverCoordinator: NSObject {
    static let popoverBehavior: NSPopover.Behavior = .applicationDefined

    private let appState: AppState
    private let presentation: MenuWindowPresentationController
    private let recordActivity: @MainActor () -> Void
    private let statusItem: NSStatusItem
    private let popover: NSPopover
    private var isInstalled = false
    private var filePickerObservation: AnyCancellable?
    private var shouldRestoreAfterChoosingMedia = false

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
        filePickerObservation = appState.$pendingAction
            .map { $0 == .choosingMedia }
            .removeDuplicates()
            .sink { [weak self] isChoosingMedia in
                self?.updateForFilePicker(isChoosingMedia: isChoosingMedia)
            }
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
        guard appState.pendingAction != .choosingMedia else { return }
        if popover.isShown {
            close()
        } else {
            show()
        }
    }

    private func updateForFilePicker(isChoosingMedia: Bool) {
        if isChoosingMedia {
            shouldRestoreAfterChoosingMedia = popover.isShown
            if shouldRestoreAfterChoosingMedia {
                // Keep disclosure and playback state for the return from the picker.
                popover.close()
            }
        } else if shouldRestoreAfterChoosingMedia {
            shouldRestoreAfterChoosingMedia = false
            // @Published emits before pendingAction is stored. Let the picker
            // finish and the workflow update before SwiftUI rebuilds the popover.
            Task { @MainActor [weak self] in
                guard let self, self.appState.pendingAction != .choosingMedia,
                      !self.popover.isShown else { return }
                self.show()
            }
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
