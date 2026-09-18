// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Owns the single temporary output used by one atomic media transaction.
package final class MediaTransactionWorkspace {
    package let temporaryOutputURL: URL

    private let directoryURL: URL
    private var committed = false

    package init(destinationURL: URL) throws {
        let parent = destinationURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(
            atPath: parent.path,
            isDirectory: &isDirectory
        ), isDirectory.boolValue else {
            throw MediaProcessingError.destinationUnavailable(parent.path)
        }
        directoryURL = parent.appendingPathComponent(
            ".speechlens-\(UUID().uuidString)",
            isDirectory: true
        )
        do {
            try FileManager.default.createDirectory(
                at: directoryURL,
                withIntermediateDirectories: false
            )
        } catch {
            throw MediaProcessingError.destinationUnavailable(error.localizedDescription)
        }
        let ext = destinationURL.pathExtension
        let stem = destinationURL.deletingPathExtension().lastPathComponent
        temporaryOutputURL = directoryURL
            .appendingPathComponent("\(stem).partial.\(ext)")
    }

    deinit { cleanup() }

    package func commit(to destinationURL: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: destinationURL.path) {
            _ = try manager.replaceItemAt(
                destinationURL,
                withItemAt: temporaryOutputURL
            )
        } else {
            try manager.moveItem(at: temporaryOutputURL, to: destinationURL)
        }
        committed = true
        try? manager.removeItem(at: directoryURL)
    }

    package func cleanup() {
        guard !committed else { return }
        try? FileManager.default.removeItem(at: directoryURL)
    }
}
