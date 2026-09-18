// SPDX-License-Identifier: Apache-2.0

import Foundation

protocol ModelArtifactDownloading: Sendable {
    func fetchData(from url: URL) async throws -> Data
    func fetchFile(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL
}

struct URLSessionModelArtifactDownloader: ModelArtifactDownloading {
    func fetchData(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        try Self.validateHTTPResponse(response, url: url)
        return data
    }

    func fetchFile(
        from url: URL,
        progress: @escaping @Sendable (Int64, Int64?) -> Void
    ) async throws -> URL {
        try await ModelDownloadDelegate.download(from: url, progress: progress)
    }

    private static func validateHTTPResponse(_ response: URLResponse, url: URL) throws {
        guard let httpResponse = response as? HTTPURLResponse else { return }
        guard (200..<300).contains(httpResponse.statusCode) else {
            throw ModelStoreError.httpStatus(httpResponse.statusCode, url.lastPathComponent)
        }
    }
}

// SAFETY: Setup completes before task resume; later mutations use URLSession's serial delegate queue.
private final class ModelDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    typealias ProgressHandler = @Sendable (Int64, Int64?) -> Void

    private let sourceURL: URL
    private let progress: ProgressHandler
    private var continuation: CheckedContinuation<URL, Error>?
    private var session: URLSession?
    private var retainedURL: URL?
    private var completionError: Error?

    private init(sourceURL: URL, progress: @escaping ProgressHandler) {
        self.sourceURL = sourceURL
        self.progress = progress
    }

    static func download(
        from url: URL,
        progress: @escaping ProgressHandler
    ) async throws -> URL {
        let delegate = ModelDownloadDelegate(sourceURL: url, progress: progress)
        return try await withCheckedThrowingContinuation { continuation in
            delegate.continuation = continuation
            let session = URLSession(
                configuration: .ephemeral,
                delegate: delegate,
                delegateQueue: nil
            )
            delegate.session = session
            session.downloadTask(with: url).resume()
        }
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        progress(
            totalBytesWritten,
            totalBytesExpectedToWrite > 0 ? totalBytesExpectedToWrite : nil
        )
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        do {
            if let response = downloadTask.response as? HTTPURLResponse,
               !(200..<300).contains(response.statusCode) {
                throw ModelStoreError.httpStatus(response.statusCode, sourceURL.lastPathComponent)
            }
            let retained = FileManager.default.temporaryDirectory.appendingPathComponent(
                "speechlens-model-\(UUID().uuidString).download"
            )
            try FileManager.default.moveItem(at: location, to: retained)
            retainedURL = retained
        } catch {
            completionError = error
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        defer {
            continuation = nil
            self.session?.finishTasksAndInvalidate()
            self.session = nil
        }
        if let error {
            continuation?.resume(throwing: error)
        } else if let completionError {
            continuation?.resume(throwing: completionError)
        } else if let retainedURL {
            continuation?.resume(returning: retainedURL)
        } else {
            continuation?.resume(throwing: ModelStoreError.missingDownloadedFile)
        }
    }
}
