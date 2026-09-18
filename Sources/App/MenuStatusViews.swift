// SPDX-License-Identifier: Apache-2.0

import AppKit
import SwiftUI

struct MenuHeaderView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var modelStore: ModelStore
    @EnvironmentObject private var presentation: MenuWindowPresentationController

    var body: some View {
        HStack(spacing: 10) {
            Image("MenuBarIcon")
                .resizable()
                .renderingMode(.template)
                .frame(width: 22, height: 22)
                .foregroundStyle(.primary)
                .accessibilityHidden(true)
            Text(LocalizedStringResource.appName).font(.headline)
            Spacer()
            statusPill
            Button { presentation.requestClose() } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .symbolRenderingMode(.hierarchical)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help(closeWindowText)
            .accessibilityLabel(closeWindowText)
            .keyboardShortcut(.cancelAction)
        }
    }

    private var statusPill: some View {
        HStack(spacing: 5) {
            if app.workflow.isBusy || modelStore.state.isDownloading {
                ProgressView().controlSize(.small).scaleEffect(0.7)
            } else {
                Image(systemName: statusIcon).font(.caption2)
            }
            Text(statusTitle).font(.caption).fontWeight(.semibold).lineLimit(1)
        }
        .foregroundStyle(statusTint)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(Capsule().fill(statusTint.opacity(0.14)))
    }

    private var closeWindowText: LocalizedStringResource {
        LocalizedStringResource.appActionCloseWindow
    }

    private var statusTitle: LocalizedStringResource {
        if app.workflow.isSelectingAudioTrack {
            return LocalizedStringResource.headerStatusChooseAudio
        }
        if app.workflow.isBusy {
            return LocalizedStringResource.headerStatusProcessing
        }
        if modelStore.state.isDownloading {
            return LocalizedStringResource.headerStatusDownloading
        }
        return modelStore.state.isReady
            ? LocalizedStringResource.headerStatusModelReady
            : LocalizedStringResource.headerStatusModelMissing
    }

    private var statusIcon: String {
        if app.workflow.isSelectingAudioTrack { return "waveform" }
        switch modelStore.state {
        case .ready: return "checkmark.circle.fill"
        case .missing, .failed: return "exclamationmark.circle.fill"
        case .downloading: return "arrow.down.circle"
        }
    }

    private var statusTint: Color {
        if app.workflow.locksInputAndSettings || modelStore.state.isDownloading { return .blue }
        return modelStore.state.isReady ? .green : .orange
    }
}

struct ModelSetupSectionView: View {
    @EnvironmentObject private var app: AppState
    @EnvironmentObject private var modelStore: ModelStore

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 8) {
                if modelStore.state.isDownloading {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.subheadline).fontWeight(.semibold).lineLimit(1)
                    Text(detail).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                if !modelStore.state.isDownloading {
                    Button { app.downloadModel() } label: {
                        Label(actionTitle, systemImage: actionIcon)
                    }
                    .controlSize(.small)
                    .disabled(!app.canDownloadModel)
                }
            }
            if case .downloading(let progress) = modelStore.state {
                if let fraction = progress.fractionCompleted {
                    ProgressView(value: fraction).progressViewStyle(.linear)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let bytes = progress.bytesReceived {
                    Text(ModelSetupPresentation.downloadProgress(
                        bytes: bytes,
                        total: progress.totalBytes,
                        fraction: progress.fractionCompleted
                    ))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(nsColor: .controlBackgroundColor)))
    }

    private var title: LocalizedStringResource {
        switch modelStore.state {
        case .downloading(let progress):
            return ModelSetupPresentation.stage(for: progress.phase)
        case .failed:
            return LocalizedStringResource.modelSetupTitleDownloadFailed
        case .missing:
            return LocalizedStringResource.modelSetupTitlePreparing
        case .ready:
            return ModelSetupPresentation.title(for: modelStore.state)
        }
    }

    private var detail: LocalizedStringResource {
        switch modelStore.state {
        case .downloading(let progress):
            return progress.bytesReceived == nil
                ? LocalizedStringResource.modelSetupDetailPreparing
                : LocalizedStringResource.modelSetupDetailDownloadContinues
        case .failed, .missing:
            return ModelSetupPresentation.detail(for: modelStore.state)
        case .ready:
            return ModelSetupPresentation.detail(for: modelStore.state)
        }
    }

    private var actionTitle: LocalizedStringResource {
        if case .failed = modelStore.state {
            return LocalizedStringResource.modelActionRetry
        }
        return LocalizedStringResource.modelActionDownload
    }

    private var actionIcon: String {
        if case .failed = modelStore.state { return "arrow.clockwise" }
        return "arrow.down.circle"
    }
}
