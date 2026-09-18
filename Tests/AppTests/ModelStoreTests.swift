// SPDX-License-Identifier: Apache-2.0

import Foundation
import TestSupport
import XCTest
@testable import App

@MainActor
final class ModelStoreTests: XCTestCase {
    func testMissingCacheReportsMissing() throws {
        let context = try makeContext(modelData: Data("model".utf8))
        XCTAssertFalse(context.store.state.isReady)
        guard case .missing = context.store.state else {
            return XCTFail("Expected missing, got \(context.store.state)")
        }
    }

    func testValidCachedModelAndManifestAreReady() throws {
        let modelData = Data("valid model".utf8)
        let context = try makeContext(modelData: modelData, cachedModel: modelData)
        XCTAssertEqual(context.store.state, .ready)
    }

    func testCachedModelWithoutManifestFailsClosed() throws {
        let modelData = Data("valid model".utf8)
        let context = try makeContext(
            modelData: modelData,
            cachedModel: modelData,
            includeCachedManifest: false
        )
        guard case .failed(let failure) = context.store.state else {
            return XCTFail("Expected failure, got \(context.store.state)")
        }
        XCTAssertEqual(failure.code, .modelCacheManifestMissing)
        let detail = try XCTUnwrap(failure.technicalDetail)
        XCTAssertTrue(detail.contains("manifest"), detail)
    }

    func testMalformedManifestFailsClosed() throws {
        let modelData = Data("valid model".utf8)
        let context = try makeContext(
            modelData: modelData,
            cachedModel: modelData,
            cachedManifest: Data("not-json".utf8)
        )
        guard case .failed = context.store.state else {
            return XCTFail("Expected failure, got \(context.store.state)")
        }
    }

    func testManifestChecksumDifferentFromDescriptorFails() throws {
        let modelData = Data("valid model".utf8)
        let wrongManifest = try TestModelArtifactFactory.manifestData(
            sha256: String(repeating: "a", count: 64)
        )
        let context = try makeContext(
            modelData: modelData,
            cachedModel: modelData,
            cachedManifest: wrongManifest
        )
        guard case .failed = context.store.state else {
            return XCTFail("Expected failure, got \(context.store.state)")
        }
    }

    func testModelBytesDifferentFromDescriptorFail() throws {
        let expected = Data("expected".utf8)
        let context = try makeContext(
            modelData: expected,
            cachedModel: Data("tampered".utf8)
        )
        guard case .failed(let failure) = context.store.state else {
            return XCTFail("Expected failure, got \(context.store.state)")
        }
        XCTAssertEqual(failure.code, .modelCacheChecksumMismatch)
        let detail = try XCTUnwrap(failure.technicalDetail)
        XCTAssertTrue(detail.contains("checksum"), detail)
    }

    func testSuccessfulDownloadVerifiesInstallsAndPersists() async throws {
        let modelData = Data("downloaded model".utf8)
        let context = try makeContext(modelData: modelData, downloaderModel: modelData)

        let installed = await context.store.downloadAndInstall()
        XCTAssertTrue(installed)
        XCTAssertEqual(context.store.state, .ready)
        XCTAssertEqual(try Data(contentsOf: context.store.cachedWeightsURL), modelData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: context.store.cachedManifestURL.path))
        XCTAssertTrue(context.downloader.reportedProgress)

        let reloaded = ModelStore(
            descriptor: context.descriptor,
            cacheDirectoryURL: context.cache,
            downloader: context.downloader
        )
        XCTAssertEqual(reloaded.state, .ready)
    }

    func testDownloadRejectsManifestWithWrongChecksum() async throws {
        let modelData = Data("downloaded model".utf8)
        let wrongManifest = try TestModelArtifactFactory.manifestData(
            sha256: String(repeating: "b", count: 64)
        )
        let context = try makeContext(
            modelData: modelData,
            downloaderModel: modelData,
            downloaderManifest: wrongManifest
        )

        let installed = await context.store.downloadAndInstall()
        XCTAssertFalse(installed)
        guard case .failed(let failure) = context.store.state else {
            return XCTFail("Expected typed model failure")
        }
        XCTAssertEqual(failure.code, .modelDownloadManifestMismatch)
        let detail = try XCTUnwrap(failure.technicalDetail)
        XCTAssertTrue(
            detail.contains("Manifest does not match"),
            detail
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.store.cachedWeightsURL.path))
    }

    func testDownloadRejectsWrongModelBytesAndCleansStaging() async throws {
        let context = try makeContext(
            modelData: Data("expected".utf8),
            downloaderModel: Data("wrong".utf8)
        )

        let installed = await context.store.downloadAndInstall()
        XCTAssertFalse(installed)
        guard case .failed(let failure) = context.store.state else {
            return XCTFail("Expected typed model failure")
        }
        XCTAssertEqual(failure.code, .modelDownloadChecksumMismatch)
        XCTAssertFalse(FileManager.default.fileExists(atPath: context.store.cachedWeightsURL.path))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: context.cache.appendingPathComponent(".model_mlx.safetensors.download").path
            )
        )
    }

    func testFailedRefreshPreservesPreviouslyValidCache() async throws {
        let modelData = Data("valid model".utf8)
        let downloader = FakeDownloader(error: TestError.downloadFailed)
        let context = try makeContext(
            modelData: modelData,
            cachedModel: modelData,
            downloader: downloader
        )

        let installed = await context.store.downloadAndInstall()
        XCTAssertFalse(installed)
        XCTAssertEqual(try Data(contentsOf: context.store.cachedWeightsURL), modelData)
        context.store.refresh()
        XCTAssertEqual(context.store.state, .ready)
    }

    func testFailedVerificationPreservesPreviouslyValidCache() async throws {
        let modelData = Data("valid model".utf8)
        let context = try makeContext(
            modelData: modelData,
            cachedModel: modelData,
            downloaderModel: Data("tampered refresh".utf8)
        )

        let installed = await context.store.downloadAndInstall()

        XCTAssertFalse(installed)
        XCTAssertEqual(try Data(contentsOf: context.store.cachedWeightsURL), modelData)
        context.store.refresh()
        XCTAssertEqual(context.store.state, .ready)
    }

    private func makeContext(
        modelData: Data,
        cachedModel: Data? = nil,
        cachedManifest: Data? = nil,
        includeCachedManifest: Bool = true,
        downloaderModel: Data? = nil,
        downloaderManifest: Data? = nil,
        downloader: FakeDownloader? = nil
    ) throws -> Context {
        let root = try makeTemporaryTestDirectory(prefix: "speechlens-model-store-tests")
        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let sha = ModelStore.sha256Hex(for: modelData)
        let descriptor = try TestModelArtifactFactory.descriptor(expectedSHA256: sha)
        let manifest = try TestModelArtifactFactory.manifestData(sha256: sha)
        if let cachedModel {
            try cachedModel.write(to: cache.appendingPathComponent("model_mlx.safetensors"))
            if includeCachedManifest {
                try (cachedManifest ?? manifest).write(
                    to: cache.appendingPathComponent("conversion-manifest.json")
                )
            }
        }

        let resolvedDownloader = downloader ?? FakeDownloader(
            manifestData: downloaderManifest ?? manifest,
            modelData: downloaderModel ?? modelData
        )
        let store = ModelStore(
            descriptor: descriptor,
            cacheDirectoryURL: cache,
            downloader: resolvedDownloader
        )
        return Context(
            root: root,
            cache: cache,
            descriptor: descriptor,
            downloader: resolvedDownloader,
            store: store
        )
    }

}

private struct Context {
    let root: URL
    let cache: URL
    let descriptor: ModelArtifactDescriptor
    let downloader: FakeDownloader
    let store: ModelStore
}

private enum TestError: Error {
    case downloadFailed
    case missingFakeData
}

private final class FakeDownloader: ModelArtifactDownloading, Sendable {
    private let manifestData: Data?
    private let modelData: Data?
    private let error: TestError?
    private let didReportProgress = LockedValue(false)

    var reportedProgress: Bool {
        didReportProgress.read()
    }

    init(manifestData: Data, modelData: Data) {
        self.manifestData = manifestData
        self.modelData = modelData
        self.error = nil
    }

    init(error: TestError) {
        self.manifestData = nil
        self.modelData = nil
        self.error = error
    }

    func fetchData(from url: URL) async throws -> Data {
        if let error { throw error }
        guard let manifestData else { throw TestError.missingFakeData }
        return manifestData
    }

    func fetchFile(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        if let error { throw error }
        guard let modelData else { throw TestError.missingFakeData }
        let data = modelData
        progress(Int64(data.count), Int64(data.count))
        didReportProgress.withValue { $0 = true }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(
            "speechlens-fake-download-\(UUID().uuidString)"
        )
        try data.write(to: url)
        return url
    }
}
