// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

/// Native equal-width control for the processing-profile choices.
///
/// SwiftUI's segmented picker does not expose AppKit's segment-distribution
/// policy. This bridge keeps AppKit's native interaction and accessibility while
/// asking it to distribute all dynamically sized segments equally.
struct ProcessingProfileSegmentedControl: NSViewRepresentable {
    @Binding var selection: ProcessingProfile
    let isEnabled: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator(selection: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let control = NSSegmentedControl()
        control.segmentCount = ProcessingProfile.allCases.count
        control.segmentStyle = .rounded
        control.trackingMode = .selectOne
        control.segmentDistribution = .fillEqually
        control.target = context.coordinator
        control.action = #selector(Coordinator.selectionChanged(_:))
        control.setAccessibilityLabel(localized(
            LocalizedStringResource.profileAccessibilityLabel
        ))
        return control
    }

    func updateNSView(_ control: NSSegmentedControl, context: Context) {
        context.coordinator.selection = $selection
        for (index, profile) in ProcessingProfile.allCases.enumerated() {
            control.setLabel(
                localized(profile.title),
                forSegment: index
            )
            control.setWidth(0, forSegment: index)
        }
        control.selectedSegment = ProcessingProfile.allCases.firstIndex(of: selection) ?? -1
        control.isEnabled = isEnabled
    }

    func sizeThatFits(
        _ proposal: ProposedViewSize,
        nsView: NSSegmentedControl,
        context: Context
    ) -> CGSize? {
        let intrinsic = nsView.intrinsicContentSize
        return CGSize(width: proposal.width ?? intrinsic.width, height: intrinsic.height)
    }

    @MainActor
    final class Coordinator: NSObject {
        var selection: Binding<ProcessingProfile>

        init(selection: Binding<ProcessingProfile>) {
            self.selection = selection
        }

        @objc func selectionChanged(_ sender: NSSegmentedControl) {
            guard ProcessingProfile.allCases.indices.contains(sender.selectedSegment) else { return }
            selection.wrappedValue = ProcessingProfile.allCases[sender.selectedSegment]
        }
    }
}
