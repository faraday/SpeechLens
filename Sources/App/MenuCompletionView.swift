// SPDX-License-Identifier: Apache-2.0

import SwiftUI

struct CompletionSectionView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var playback: PlaybackController
    @State private var showsOutputDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(LocalizedStringResource.completionSectionPreview).sectionLabelStyle()
            if let outputURL = app.workflow.completedContext?.outputURL {
                HStack(spacing: 8) {
                    Text(verbatim: outputURL.lastPathComponent)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !outputDetails.isEmpty {
                        Button { showsOutputDetails.toggle() } label: {
                            Image(
                                systemName: hasWarnings
                                    ? "exclamationmark.triangle"
                                    : "info.circle"
                            )
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(hasWarnings ? Color.orange : Color.secondary)
                        .help(
                            hasWarnings
                                ? .completionOutputWarningsTitle
                                : .completionOutputDetailsTitle
                        )
                        .accessibilityLabel(
                            hasWarnings
                                ? .completionOutputWarningsTitle
                                : .completionOutputDetailsTitle
                        )
                        .popover(isPresented: $showsOutputDetails, arrowEdge: .bottom) {
                            VStack(alignment: .leading, spacing: 8) {
                                Text(
                                    hasWarnings
                                        ? .completionOutputWarningsTitle
                                        : .completionOutputDetailsTitle
                                )
                                    .font(.headline)
                                ForEach(
                                    Array(outputDetails.enumerated()),
                                    id: \.offset
                                ) { _, detail in
                                    Label {
                                        Text(detail.message)
                                            .fixedSize(
                                                horizontal: false,
                                                vertical: true
                                            )
                                            .multilineTextAlignment(.leading)
                                    } icon: {
                                        Image(
                                            systemName: detail.severity == .warning
                                                ? "exclamationmark.triangle"
                                                : "checkmark.circle"
                                        )
                                        .foregroundStyle(
                                            detail.severity == .warning
                                                ? Color.orange
                                                : Color.secondary
                                        )
                                    }
                                    .font(.caption)
                                    .frame(
                                        maxWidth: .infinity,
                                        alignment: .leading
                                    )
                                }
                            }
                            .padding(12)
                            .frame(width: 320, alignment: .leading)
                        }
                    }
                    Spacer()
                    Button { app.revealOutput() } label: {
                        Label(
                            LocalizedStringResource.completionActionReveal,
                            systemImage: "folder"
                        )
                    }
                    .controlSize(.small)
                }
            }
            HStack(spacing: 8) {
                Button { playback.togglePlayback() } label: {
                    Label(
                        playback.isPlaying
                            ? LocalizedStringResource.playbackActionPause
                            : LocalizedStringResource.playbackActionPlay,
                        systemImage: playback.isPlaying ? "pause.fill" : "play.fill"
                    ).frame(minWidth: 76)
                }
                .buttonStyle(.borderedProminent)
                .disabled(playback.duration <= 0)
                Spacer()
                Picker(selection: Binding(
                    get: { playback.selection },
                    set: { playback.select($0) }
                )) {
                    ForEach(PlaybackSelection.allCases) { selection in
                        Text(selection.title).tag(selection)
                    }
                } label: {
                    Text(LocalizedStringResource.playbackSourcePicker)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .disabled(playback.duration <= 0)
            }
            WaveformScrubber(
                levels: playback.activeWaveformLevels,
                progress: playback.progress,
                duration: playback.duration,
                onSeek: playback.seek
            )
            .frame(height: 42)
            .disabled(playback.duration <= 0)
            HStack {
                Spacer()
                Text(verbatim: "\(formatDuration(playback.progress)) / \(formatDuration(playback.duration))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let issue = playback.issue {
                Text(PlaybackIssuePresentation.message(for: issue))
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }
        }
    }

    private var outputDetails: [OutputDetail] {
        guard let context = app.workflow.completedContext else { return [] }
        return OutputDetailsBuilder.build(
            preparedJob: context.preparedJob,
            notices: context.notices
        )
    }

    private var hasWarnings: Bool {
        app.workflow.completedContext?.hasWarnings == true
    }
}
