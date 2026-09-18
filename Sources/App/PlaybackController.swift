// SPDX-License-Identifier: Apache-2.0

import AudioIO
import AVFoundation
import Combine
import Diagnostics
import Foundation
import MediaIO
import Processing

enum PlaybackSelection: CaseIterable, Identifiable {
    case original
    case enhanced

    var id: Self { self }

    var title: LocalizedStringResource {
        switch self {
        case .original:
            LocalizedStringResource.playbackSourceOriginal
        case .enhanced:
            LocalizedStringResource.playbackSourceEnhanced
        }
    }
}

enum PlaybackIssue: Sendable, Equatable {
    case previewFileMissing

    var code: DiagnosticFailureCode { .playbackPreviewFileMissing }
}

enum PlaybackIssuePresentation {
    static func message(
        for issue: PlaybackIssue
    ) -> LocalizedStringResource {
        AppFailurePresentation.message(for: issue.code)
    }
}

@MainActor
final class PlaybackController: ObservableObject {
    @Published private(set) var selection: PlaybackSelection = .enhanced
    @Published private(set) var isPlaying = false
    @Published private(set) var progress: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var issue: PlaybackIssue?
    @Published private(set) var originalWaveformLevels: [Double] = []
    @Published private(set) var enhancedWaveformLevels: [Double] = []

    private var originalPlayer: AVPlayer?
    private var enhancedPlayer: AVPlayer?
    // AVFoundation observer tokens must also be removed when this main-actor
    // controller is deinitialized, which Swift performs nonisolated.
    nonisolated(unsafe) private var observedPlayer: AVPlayer?
    nonisolated(unsafe) private var periodicTimeObserver: Any?
    nonisolated(unsafe) private var playbackEndObserver: NSObjectProtocol?
    private var waveformGeneration = UUID()
    private var previewAssets: MediaPreviewAssets?

    var activeWaveformLevels: [Double] {
        selection == .original ? originalWaveformLevels : enhancedWaveformLevels
    }

    func setOriginalSamples(_ samples: [Float]) {
        originalWaveformLevels = Self.waveformLevels(for: samples)
    }

    func setEnhancedSamples(_ samples: [Float]) {
        enhancedWaveformLevels = Self.waveformLevels(for: samples)
    }

    func prepareComparison(
        inputURL: URL,
        outputURL: URL,
        durationSeconds: Double? = nil
    ) {
        previewAssets = nil
        removePlaybackObservers()
        stop(resetPosition: true)
        waveformGeneration = UUID()
        originalWaveformLevels = []
        enhancedWaveformLevels = []
        issue = nil
        guard FileManager.default.fileExists(atPath: inputURL.path),
              FileManager.default.fileExists(atPath: outputURL.path) else {
            originalPlayer = nil
            enhancedPlayer = nil
            duration = 0
            progress = 0
            issue = .previewFileMissing
            return
        }

        originalPlayer = AVPlayer(url: inputURL)
        enhancedPlayer = AVPlayer(url: outputURL)
        selection = .enhanced
        let seconds = durationSeconds
            ?? (try? AudioFileInfoReader().readInfo(from: outputURL).durationSeconds)
            ?? 0
        duration = seconds.isFinite && seconds > 0 ? seconds : 0
        progress = 0
        installPlaybackObservers()
    }

    func prepareComparison(
        previewAssets: MediaPreviewAssets,
        durationSeconds: Double
    ) {
        prepareComparison(
            inputURL: previewAssets.inputAudioURL,
            outputURL: previewAssets.outputAudioURL,
            durationSeconds: durationSeconds
        )
        self.previewAssets = previewAssets
        originalWaveformLevels = previewAssets.originalWaveformLevels
        enhancedWaveformLevels = previewAssets.enhancedWaveformLevels
    }

    /// Builds fixed-size display envelopes through bounded secondary file scans.
    func loadWaveforms(
        inputURL: URL,
        outputURL: URL,
        inputAudioStreamIndex: Int,
        outputAudioStreamIndex: Int
    ) async {
        let generation = waveformGeneration
        do {
            async let original = Task.detached {
                try await MediaWaveformEnvelope().levels(
                    from: inputURL,
                    selectingAudioStreamIndex: inputAudioStreamIndex
                )
            }.value
            async let enhanced = Task.detached {
                try await MediaWaveformEnvelope().levels(
                    from: outputURL,
                    selectingAudioStreamIndex: outputAudioStreamIndex
                )
            }.value
            let (originalLevels, enhancedLevels) = try await (original, enhanced)
            guard waveformGeneration == generation else { return }
            originalWaveformLevels = originalLevels
            enhancedWaveformLevels = enhancedLevels
        } catch {
            // Waveform presentation is non-critical; file playback remains available.
        }
    }

    func select(_ newSelection: PlaybackSelection) {
        guard newSelection != selection else { return }
        let currentTime = activePlayer?.currentTime().seconds ?? progress
        let shouldContinuePlaying = (activePlayer?.rate ?? 0) > 0
        activePlayer?.pause()
        selection = newSelection
        installPlaybackObservers()
        guard let player = activePlayer else {
            isPlaying = false
            return
        }
        let bounded = max(0, min(currentTime, duration))
        player.seek(to: CMTime(seconds: bounded, preferredTimescale: 600))
        progress = bounded
        if shouldContinuePlaying {
            player.play()
            isPlaying = true
        } else {
            isPlaying = false
        }
    }

    func togglePlayback() {
        guard let player = activePlayer else { return }
        if player.rate > 0 {
            player.pause()
            isPlaying = false
            synchronizeProgress()
            return
        }
        if player.currentTime().seconds >= duration { seek(to: 0) }
        player.play()
        isPlaying = true
    }

    func seek(to time: Double) {
        let bounded = max(0, min(time, duration))
        let target = CMTime(seconds: bounded, preferredTimescale: 600)
        originalPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        enhancedPlayer?.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
        progress = bounded
    }

    func stop(resetPosition: Bool) {
        originalPlayer?.pause()
        enhancedPlayer?.pause()
        isPlaying = false
        if resetPosition {
            originalPlayer?.seek(to: .zero)
            enhancedPlayer?.seek(to: .zero)
            progress = 0
        } else {
            synchronizeProgress()
        }
    }

    func reset() {
        stop(resetPosition: true)
        removePlaybackObservers()
        waveformGeneration = UUID()
        originalPlayer = nil
        enhancedPlayer = nil
        previewAssets = nil
        selection = .enhanced
        duration = 0
        issue = nil
        originalWaveformLevels = []
        enhancedWaveformLevels = []
    }

    nonisolated static func waveformLevels(
        for samples: [Float],
        binCount: Int = 96
    ) -> [Double] {
        guard !samples.isEmpty, binCount > 0 else { return [] }
        let samplesPerBin = max(1, samples.count / binCount)
        var levels: [Double] = []
        levels.reserveCapacity(binCount)
        var index = 0
        while index < samples.count && levels.count < binCount {
            let end = min(samples.count, index + samplesPerBin)
            var peak: Float = 0
            for sampleIndex in index..<end { peak = max(peak, abs(samples[sampleIndex])) }
            levels.append(Double(peak))
            index = end
        }
        return normalizedWaveformLevels(levels.map(Float.init))
    }

    private var activePlayer: AVPlayer? {
        selection == .original ? originalPlayer : enhancedPlayer
    }

    private func installPlaybackObservers() {
        removePlaybackObservers()
        guard let player = activePlayer else { return }
        observedPlayer = player
        periodicTimeObserver = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.1, preferredTimescale: 600),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.synchronizeProgress()
            }
        }
        if let item = player.currentItem {
            playbackEndObserver = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: item,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.progress = self.duration
                    self.isPlaying = false
                }
            }
        }
    }

    private func removePlaybackObservers() {
        if let periodicTimeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(periodicTimeObserver)
        }
        periodicTimeObserver = nil
        observedPlayer = nil
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
        playbackEndObserver = nil
    }

    private func synchronizeProgress() {
        guard let player = activePlayer else {
            progress = 0
            isPlaying = false
            return
        }
        let seconds = player.currentTime().seconds
        progress = seconds.isFinite ? max(0, min(seconds, duration)) : 0
        if player.rate == 0 {
            isPlaying = false
        }
    }

    private nonisolated static func normalizedWaveformLevels(_ levels: [Float]) -> [Double] {
        let maximum = levels.max() ?? 0
        guard maximum > 0 else { return Array(repeating: 0.08, count: levels.count) }
        return levels.map { max(0.08, pow(Double($0 / maximum), 0.7)) }
    }

    deinit {
        if let periodicTimeObserver, let observedPlayer {
            observedPlayer.removeTimeObserver(periodicTimeObserver)
        }
        if let playbackEndObserver {
            NotificationCenter.default.removeObserver(playbackEndObserver)
        }
    }
}
