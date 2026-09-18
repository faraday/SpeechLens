// SPDX-License-Identifier: Apache-2.0

import MediaIO
import SwiftUI
import UniformTypeIdentifiers

struct WorkflowSectionView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 30))
                .foregroundStyle(.secondary)
            Text(LocalizedStringResource.workflowDropPrompt)
                .font(.subheadline).foregroundStyle(.secondary)
            Button { app.pickAndProcess() } label: {
                Label(
                    LocalizedStringResource.workflowActionChooseMedia,
                    systemImage: "waveform"
                ).frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!app.canStartProcessing)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 18)
        .padding(.horizontal, 12)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(
                    Color.secondary.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1, dash: [4])
                )
        )
        .dropDestination(for: URL.self) { urls, _ in
            guard app.canStartProcessing, let url = urls.first else { return false }
            app.process(inputURL: url)
            return true
        }
    }

}

struct SelectedFileSectionView: View {
    @EnvironmentObject private var app: AppState
    let url: URL

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(LocalizedStringResource.workflowSelectedSection)
                .sectionLabelStyle()
            HStack(spacing: 8) {
                Image(systemName: "waveform").foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(verbatim: url.lastPathComponent)
                        .font(.subheadline).lineLimit(1).truncationMode(.middle)
                    if let info = app.workflow.audioInfo {
                        Text(verbatim: "\(formatDuration(info.durationSeconds)) - \(formatSampleRate(info.sampleRate)) - \(channelLayoutLabel(info.channelCount))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }
            if app.workflow.isBusy, let outputURL = app.workflow.plannedOutputURL {
                HStack(spacing: 8) {
                    Image(systemName: "folder").foregroundStyle(.secondary)
                    Text(LocalizedStringResource.workflowSelectedOutputFilename(
                        outputURL.lastPathComponent
                    ))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
    }
}

struct AudioTrackSelectionSectionView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        if case .selectingAudioTrack(let context) = app.workflow {
            VStack(alignment: .leading, spacing: 12) {
                Label(
                    LocalizedStringResource.workflowTrackSelectionMultipleFound,
                    systemImage: "info.circle"
                )
                    .font(.caption)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 5) {
                    Text(LocalizedStringResource.workflowTrackSelectionLabel)
                        .font(.caption).foregroundStyle(.secondary)
                    Picker(selection: Binding(
                        get: { context.selectedStreamIndex },
                        set: { app.selectAudioTrack($0) }
                    )) {
                        ForEach(context.inspection.mediaInspection.audioTracks) { track in
                            Text(verbatim: audioTrackLabel(
                                track,
                                among: context.inspection.mediaInspection.audioTracks
                            ))
                                .tag(track.streamIndex)
                                .disabled(!track.isSelectable)
                        }
                    } label: {
                        Text(LocalizedStringResource.workflowTrackSelectionLabel)
                    }
                    .labelsHidden()
                    .frame(maxWidth: .infinity)
                    .help(context.selectedTrack?.isSelectable == false
                        ? LocalizedStringResource.workflowTrackSelectionUnavailableHelp
                        : LocalizedStringResource.workflowTrackSelectionHelp)
                }
                HStack {
                    Spacer()
                    Button(LocalizedStringResource.commonActionCancel) {
                        app.cancelAudioTrackSelection()
                    }
                    Button(LocalizedStringResource.workflowActionEnhanceSpeech) {
                        app.confirmAudioTrackSelection()
                    }
                        .buttonStyle(.borderedProminent)
                        .disabled(context.selectedTrack?.isSelectable != true)
                }
            }
        }
    }

}

struct ProcessingSectionView: View {
    @EnvironmentObject private var app: AppState

    var body: some View {
        Group {
            if let label = AppWorkflowPresentation.stageLabel(for: app.workflow) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        if !app.workflow.isBusy {
                            Image(systemName: icon).foregroundStyle(tint)
                        }
                        Text(label)
                            .font(.caption)
                            .foregroundStyle(app.workflow.isBusy ? .primary : tint)
                            .lineLimit(2)
                            .fixedSize(horizontal: false, vertical: true)
                        if let seconds = app.workflow.completedContext?.processingDurationSeconds {
                            let elapsed = formatElapsedDuration(seconds)
                            Text(LocalizedStringResource.workflowCompletedElapsed(
                                elapsed
                            ))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .accessibilityLabel(
                                    LocalizedStringResource
                                        .workflowCompletedElapsedAccessibility(elapsed)
                                )
                        }
                        Spacer()
                        if app.workflow.isBusy {
                            Button(LocalizedStringResource.commonActionCancel) {
                                app.cancelProcessing()
                            }.controlSize(.small)
                        }
                    }
                    if let progress = app.workflow.progress {
                        ProgressView(value: progress.fractionCompleted).progressViewStyle(.linear)
                    }
                }
            }
        }
    }

    private var icon: String {
        switch app.workflow {
        case .completed: return "checkmark.circle.fill"
        case .failed: return "xmark.octagon.fill"
        default: return "circle"
        }
    }

    private var tint: Color {
        switch app.workflow {
        case .completed: return .green
        case .failed: return .red
        default: return .secondary
        }
    }
}
