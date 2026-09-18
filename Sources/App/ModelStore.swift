// SPDX-License-Identifier: Apache-2.0

import Combine
import Diagnostics
import Foundation

enum ModelSetupState: Sendable, Equatable {
    case ready
    case missing
    case downloading(ModelDownloadProgress)
    case failed(ModelSetupFailure)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct ModelSetupFailure: Sendable, Equatable {
    let code: DiagnosticFailureCode
    let technicalDetail: String?
}

enum ModelDownloadPhase: String, Codable, Sendable, Equatable {
    case preparing
    case downloading
    case verifying
}

struct ModelDownloadProgress: Sendable, Equatable {
    let phase: ModelDownloadPhase
    let bytesReceived: Int64?
    let totalBytes: Int64?

    var fractionCompleted: Double? {
        guard let bytesReceived, let totalBytes, totalBytes > 0 else { return nil }
        return min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
    }

    static func preparing(_ phase: ModelDownloadPhase) -> Self {
        Self(phase: phase, bytesReceived: nil, totalBytes: nil)
    }

    static func downloading(bytesReceived: Int64, totalBytes: Int64?) -> Self {
        Self(
            phase: .downloading,
            bytesReceived: bytesReceived,
            totalBytes: totalBytes
        )
    }
}

@MainActor
final class ModelStore: ObservableObject {
    @Published private(set) var state: ModelSetupState

    let descriptor: ModelArtifactDescriptor
    let cacheDirectoryURL: URL

    var cachedWeightsURL: URL {
        cacheDirectoryURL.appendingPathComponent("model_mlx.safetensors")
    }

    var cachedManifestURL: URL {
        cacheDirectoryURL.appendingPathComponent("conversion-manifest.json")
    }

    var weightsURL: URL { cachedWeightsURL }

    private let downloader: any ModelArtifactDownloading
    private let artifacts: ModelArtifactRepository

    init(
        descriptor: ModelArtifactDescriptor = .current,
        cacheDirectoryURL: URL = ModelStore.defaultCacheDirectoryURL(),
        downloader: any ModelArtifactDownloading = URLSessionModelArtifactDownloader(),
        fileManager: FileManager = .default
    ) {
        self.descriptor = descriptor
        self.cacheDirectoryURL = cacheDirectoryURL
        self.downloader = downloader
        self.artifacts = ModelArtifactRepository(fileManager: fileManager)
        self.state = .missing
        self.state = evaluateState()
    }

    func refresh() {
        state = evaluateState()
    }

    @discardableResult
    func downloadAndInstall(
        onProgress: (@MainActor @Sendable (ModelDownloadProgress) -> Void)? = nil
    ) async -> Bool {
        if case .downloading = state { return false }
        state = .downloading(.preparing(.preparing))
        if case .downloading(let progress) = state { onProgress?(progress) }

        let stagingModelURL = cacheDirectoryURL.appendingPathComponent(
            ".model_mlx.safetensors.download"
        )
        do {
            try artifacts.prepareStagingDirectory(
                cacheDirectoryURL: cacheDirectoryURL,
                stagingURL: stagingModelURL
            )
            let manifestData = try await downloader.fetchData(from: descriptor.manifestURL)
            let manifestSHA = try ModelArtifactVerifier.expectedModelSHA256(from: manifestData)
            guard manifestSHA.caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame else {
                throw ModelStoreError.manifestChecksumMismatch
            }

            state = .downloading(.downloading(bytesReceived: 0, totalBytes: nil))
            if case .downloading(let progress) = state { onProgress?(progress) }
            let downloadedURL = try await downloader.fetchFile(
                from: descriptor.modelDownloadURL
            ) { [weak self] bytesReceived, totalBytes in
                Task { @MainActor in
                    let progress = ModelDownloadProgress.downloading(
                        bytesReceived: bytesReceived,
                        totalBytes: totalBytes
                    )
                    self?.state = .downloading(progress)
                    onProgress?(progress)
                }
            }
            defer { artifacts.removeIfPresent(downloadedURL) }
            try artifacts.moveDownloadedFile(downloadedURL, to: stagingModelURL)

            state = .downloading(.preparing(.verifying))
            if case .downloading(let progress) = state { onProgress?(progress) }
            let actualSHA = try ModelArtifactVerifier.sha256Hex(forFileAt: stagingModelURL)
            guard actualSHA.caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame else {
                throw ModelStoreError.checksumMismatch
            }

            try artifacts.installVerifiedModel(
                from: stagingModelURL,
                manifestData: manifestData,
                weightsURL: cachedWeightsURL,
                manifestURL: cachedManifestURL
            )
            refresh()
            return state.isReady
        } catch {
            artifacts.removeIfPresent(stagingModelURL)
            state = .failed(Self.failure(for: error))
            return false
        }
    }

    static func expectedModelSHA256(from manifestData: Data) throws -> String {
        try ModelArtifactVerifier.expectedModelSHA256(from: manifestData)
    }

    static func sha256Hex(for data: Data) -> String {
        ModelArtifactVerifier.sha256Hex(for: data)
    }

    static func sha256Hex(forFileAt url: URL) throws -> String {
        try ModelArtifactVerifier.sha256Hex(forFileAt: url)
    }

    private func evaluateState() -> ModelSetupState {
        artifacts.evaluateState(
            weightsURL: cachedWeightsURL,
            manifestURL: cachedManifestURL,
            descriptor: descriptor
        )
    }

    private static func defaultCacheDirectoryURL() -> URL {
        let base = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first ?? FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("SpeechLens/Models", isDirectory: true)
    }

    private static func failure(for error: Error) -> ModelSetupFailure {
        if let error = error as? ModelStoreError {
            return ModelSetupFailure(
                code: error.failureCode,
                technicalDetail: "Download failed: \(error.message)"
            )
        }
        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain {
            return ModelSetupFailure(
                code: .modelDownloadNetwork,
                technicalDetail: "Download failed: \(nsError.localizedDescription)"
            )
        }
        return ModelSetupFailure(
            code: .modelDownloadInstallation,
            technicalDetail: "Download failed: Check the connection and retry."
        )
    }
}

enum ModelSetupPresentation {
    static func title(for state: ModelSetupState) -> LocalizedStringResource {
        switch state {
        case .ready:
            return LocalizedStringResource.modelTitleReadyDefault
        case .missing:
            return LocalizedStringResource.modelTitleMissing
        case .downloading:
            return LocalizedStringResource.modelTitleDownloading
        case .failed:
            return LocalizedStringResource.modelTitleFailed
        }
    }

    static func detail(for state: ModelSetupState) -> LocalizedStringResource {
        switch state {
        case .ready:
            return LocalizedStringResource.modelDetailReadyDefault
        case .missing:
            return LocalizedStringResource.modelDetailMissing
        case .failed(let failure):
            return AppFailurePresentation.message(for: failure.code)
        case .downloading(let progress):
            return stage(for: progress.phase)
        }
    }

    static func stage(
        for phase: ModelDownloadPhase
    ) -> LocalizedStringResource {
        switch phase {
        case .preparing:
            return LocalizedStringResource.modelStagePreparing
        case .downloading:
            return LocalizedStringResource.modelStageDownloading
        case .verifying:
            return LocalizedStringResource.modelStageVerifying
        }
    }

    static func downloadProgress(
        bytes: Int64,
        total: Int64?,
        fraction: Double?,
        locale: Locale = .current
    ) -> LocalizedStringResource {
        let style = ByteCountFormatStyle(style: .file).locale(locale)
        let received = bytes.formatted(style)
        guard let total, total > 0 else {
            return .modelDownloadProgressReceived(received)
        }
        let totalLabel = total.formatted(style)
        let percentage = Int(((fraction ?? 0) * 100).rounded())
        return .modelDownloadProgressReceivedTotal(
            received,
            totalLabel,
            percentage
        )
    }
}
