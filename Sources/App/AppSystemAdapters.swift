// SPDX-License-Identifier: Apache-2.0

import AppKit
import AudioIO
import Foundation
import MediaIO
import Processing
import UniformTypeIdentifiers

protocol MediaJobPreparing: Sendable {
    func inspect(_ url: URL) async throws -> InspectedMediaJob
    func prepare(
        _ inspection: InspectedMediaJob,
        selectedAudioStreamIndex: Int,
        options: MediaProcessingOptions,
        destinationPlanner: @escaping MediaJobPreparer.DestinationPlanner
    ) async throws -> PreparedMediaJob
}

struct AppInspectedMedia: Sendable, Equatable {
    let audioInfo: AudioFileInfo
    let mediaInfo: MediaFileInfo?
    let outputPlan: MediaOutputPlan?

    init(
        audioInfo: AudioFileInfo,
        mediaInfo: MediaFileInfo? = nil,
        outputPlan: MediaOutputPlan? = nil
    ) {
        self.audioInfo = audioInfo
        self.mediaInfo = mediaInfo
        self.outputPlan = outputPlan
    }

    init(preparedJob: PreparedMediaJob) {
        audioInfo = preparedJob.inputInfo.selectedAudio.audioFileInfo
        mediaInfo = preparedJob.inputInfo
        outputPlan = preparedJob.outputPlan
    }
}

struct NativeMediaJobPreparer: MediaJobPreparing {
    func inspect(_ url: URL) async throws -> InspectedMediaJob {
        try await MediaJobPreparer().inspect(inputURL: url)
    }

    func prepare(
        _ inspection: InspectedMediaJob,
        selectedAudioStreamIndex: Int,
        options: MediaProcessingOptions,
        destinationPlanner: @escaping MediaJobPreparer.DestinationPlanner
    ) async throws -> PreparedMediaJob {
        try await MediaJobPreparer().prepare(
            inspection: inspection,
            selectedAudioStreamIndex: selectedAudioStreamIndex,
            options: options,
            destinationPlanner: destinationPlanner
        )
    }

}

@MainActor
protocol AppFileChoosing: AnyObject {
    func chooseMedia() async -> URL?
}

@MainActor
final class AppKitFileChooser: AppFileChoosing {
    func chooseMedia() async -> URL? {
        let panel = NSOpenPanel()
        panel.title = localized(
            LocalizedStringResource.panelChooseMediaTitle
        )
        panel.allowsMultipleSelection = false
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowedContentTypes = [.audio, .movie, .wav, .aiff]
        if let flac = UTType(filenameExtension: "flac"),
           !panel.allowedContentTypes.contains(flac) {
            panel.allowedContentTypes.append(flac)
        }
        return await present(panel)
    }

    private func present(_ panel: NSOpenPanel) async -> URL? {
        NSApp.activate(ignoringOtherApps: true)
        return await withCheckedContinuation { continuation in
            panel.begin { response in
                continuation.resume(returning: response == .OK ? panel.url : nil)
            }
        }
    }
}

@MainActor
protocol OutputRevealing: AnyObject {
    func reveal(_ url: URL)
}

@MainActor
final class WorkspaceOutputRevealer: OutputRevealing {
    func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
