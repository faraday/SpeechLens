// SPDX-License-Identifier: Apache-2.0

import Foundation
import os

/// A separate route for each SDK client. Sentry can keep scheduling tasks after
/// close(), so only the session that actually makes network requests is invalidated.
final class SentryConsentTransport {
    let sdkSession: URLSession
    private let route: String

    init(networkSession: URLSession) {
        let route = UUID().uuidString
        self.route = route
        SentryUploadProtocol.routes.withLock { $0[route] = networkSession }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpAdditionalHeaders = [SentryUploadProtocol.routeHeader: route]
        configuration.protocolClasses = [SentryUploadProtocol.self]
        sdkSession = URLSession(configuration: configuration)
    }

    func revoke() {
        let route = route
        let session = SentryUploadProtocol.routes.withLock { $0.removeValue(forKey: route) }
        session?.invalidateAndCancel()
    }

    deinit { revoke() }
}

private final class SentryUploadProtocol: URLProtocol, @unchecked Sendable {
    static let routeHeader = "X-SpeechLens-Local-Sentry-Route"
    static let routes = OSAllocatedUnfairLock(initialState: [String: URLSession]())

    private let taskLock = NSLock()
    private var uploadTask: URLSessionDataTask?
    private var stopped = false

    override class func canInit(with request: URLRequest) -> Bool { true }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var request = request
        let route = request.value(forHTTPHeaderField: Self.routeHeader)
        request.setValue(nil, forHTTPHeaderField: Self.routeHeader)
        let upload = request

        let shouldReject = taskLock.withLock {
            guard !stopped else { return false }
            // Removing a route and creating its tasks are mutually exclusive.
            uploadTask = Self.routes.withLock { sessions in
                guard let route, let session = sessions[route] else { return nil }
                let task = session.dataTask(with: upload) { [weak self] data, response, error in
                    self?.complete(data: data, response: response, error: error)
                }
                task.resume()
                return task
            }
            return uploadTask == nil
        }
        if shouldReject {
            client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
        }
    }

    override func stopLoading() {
        let task = taskLock.withLock {
            stopped = true
            let pending = uploadTask
            uploadTask = nil
            return pending
        }
        task?.cancel()
    }

    private func complete(data: Data?, response: URLResponse?, error: Error?) {
        guard taskLock.withLock({ !stopped }) else { return }
        if let response {
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        }
        if let data, !data.isEmpty {
            client?.urlProtocol(self, didLoad: data)
        }
        if let error {
            client?.urlProtocol(self, didFailWithError: error)
        } else {
            client?.urlProtocolDidFinishLoading(self)
        }
    }
}
