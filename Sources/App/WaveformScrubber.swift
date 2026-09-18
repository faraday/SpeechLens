// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct WaveformScrubber: View {
    let levels: [Double]
    let progress: Double
    let duration: Double
    let onSeek: (Double) -> Void
    @Environment(\.accessibilityDifferentiateWithoutColor)
    private var differentiateWithoutColor

    var body: some View {
        GeometryReader { proxy in
            let width = max(proxy.size.width, 1)
            let fraction = duration > 0 ? min(max(progress / duration, 0), 1) : 0
            let cursorX = width * fraction

            Canvas { context, size in
                let levels = levels.isEmpty ? Array(repeating: 0.08, count: 64) : levels
                let step = size.width / CGFloat(levels.count)
                let barWidth = max(1.5, step * 0.56)
                let midY = size.height / 2

                for (index, level) in levels.enumerated() {
                    let x = CGFloat(index) * step + (step - barWidth) / 2
                    let barHeight = max(3, size.height * CGFloat(level) * 0.86)
                    let rect = CGRect(
                        x: x,
                        y: midY - barHeight / 2,
                        width: barWidth,
                        height: barHeight
                    )
                    let color = x <= cursorX
                        ? Color.accentColor
                        : Color.secondary.opacity(0.5)
                    context.fill(
                        Path(roundedRect: rect, cornerRadius: barWidth / 2),
                        with: .color(color)
                    )
                }

                let cursorRect = CGRect(
                    x: min(max(cursorX - 1, 0), size.width - 2),
                    y: 1,
                    width: 2,
                    height: size.height - 2
                )
                context.fill(
                    Path(roundedRect: cursorRect, cornerRadius: 1),
                    with: .color(.primary.opacity(0.9))
                )
            }
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        guard duration > 0 else { return }
                        let fraction = min(max(value.location.x / width, 0), 1)
                        onSeek(duration * fraction)
                    }
            )
            .focusable(duration > 0)
            .onKeyPress(.leftArrow) {
                seek(by: -keyboardStep)
                return .handled
            }
            .onKeyPress(.rightArrow) {
                seek(by: keyboardStep)
                return .handled
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(
                LocalizedStringResource.playbackScrubberAccessibilityLabel
            )
            .accessibilityValue(
                LocalizedStringResource.playbackScrubberAccessibilityValue(
                    formatDuration(progress),
                    formatDuration(duration)
                )
            )
            .accessibilityAdjustableAction { direction in
                switch direction {
                case .increment:
                    seek(by: keyboardStep)
                case .decrement:
                    seek(by: -keyboardStep)
                @unknown default:
                    break
                }
            }
            .overlay {
                if differentiateWithoutColor {
                    Rectangle()
                        .fill(Color.primary.opacity(0.8))
                        .frame(width: 1)
                        .offset(x: cursorX - width / 2)
                        .allowsHitTesting(false)
                }
            }
        }
    }

    private var keyboardStep: Double {
        min(max(duration * 0.05, 1), 10)
    }

    private func seek(by delta: Double) {
        guard duration > 0 else { return }
        onSeek(min(max(progress + delta, 0), duration))
    }
}
