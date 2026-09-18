// SPDX-License-Identifier: Apache-2.0

import Diagnostics
import Foundation
import XCTest
@testable import App

enum AppTestSupportError: Error {
    case defaultsUnavailable
    case invalidURL(String)
}

/// Renders a localized resource against the committed English catalog.
func englishText(_ resource: LocalizedStringResource) -> String {
    localized(resource, locale: Locale(identifier: "en"))
}

enum AppPrivacyTestFixture {
    static let privatePathPrefix = "/Users/privacy-test-user/Private"
    static let inputURL = URL(
        fileURLWithPath: "\(privatePathPrefix)/Sensitive Interview.wav"
    )
    static let outputURL = URL(
        fileURLWithPath: "\(privatePathPrefix)/Sensitive Interview-enhanced.mov"
    )
    static let modelURL = URL(
        fileURLWithPath: "\(privatePathPrefix)/model.safetensors"
    )
    static let sensitiveTitle = "Sensitive Interview"
    static let sensitiveLanguage = "privacy-test-language"
    static let sensitiveHost = "privacy-test.invalid"
}

@MainActor
extension XCTestCase {
    func makeTemporaryTestDirectory(prefix: String) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(
            "\(prefix)-\(UUID().uuidString)",
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func makeIsolatedDefaults(prefix: String) throws -> UserDefaults {
        let suiteName = "\(prefix).\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            throw AppTestSupportError.defaultsUnavailable
        }
        addTeardownBlock { defaults.removePersistentDomain(forName: suiteName) }
        return defaults
    }

    func makeDiagnosticRecorder(prefix: String) throws -> AppDiagnosticRecorder {
        let root = try makeTemporaryTestDirectory(prefix: prefix)
        return AppDiagnosticRecorder(
            store: DiagnosticSnapshotStore(
                fileURL: root.appendingPathComponent("latest-operation.json")
            )
        )
    }
}

enum TestModelArtifactFactory {
    static func descriptor(expectedSHA256: String) throws -> ModelArtifactDescriptor {
        ModelArtifactDescriptor(
            version: "test",
            revision: "test-revision",
            expectedSHA256: expectedSHA256,
            expectedSizeBytes: 1_000_000,
            sourceModelURL: try url("https://example.com/source"),
            convertedWeightsURL: try url("https://example.com/converted"),
            licenseURL: try url("https://example.com/license"),
            manifestURL: try url("https://example.com/manifest.json"),
            modelDownloadURL: try url("https://example.com/model.safetensors")
        )
    }

    static func manifestData(sha256: String) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["model_sha256": sha256])
    }

    private static func url(_ literal: String) throws -> URL {
        guard let url = URL(string: literal) else {
            throw AppTestSupportError.invalidURL(literal)
        }
        return url
    }
}

@MainActor
final class ControllableAsyncResult<Value: Sendable> {
    private var continuation: CheckedContinuation<Value, Never>?

    func wait() async -> Value {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resolve(_ value: Value) {
        continuation?.resume(returning: value)
        continuation = nil
    }
}

actor ControllableAsyncGate {
    private var waiters = [CheckedContinuation<Void, Never>]()

    func wait() async {
        await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    func open() {
        let pending = waiters
        waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}
