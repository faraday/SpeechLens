// SPDX-License-Identifier: Apache-2.0

import Foundation
import MediaIO

struct OutputURLPlanner: Sendable {
    private let fileExists: @Sendable (String) -> Bool

    init(fileExists: @escaping @Sendable (String) -> Bool = {
        FileManager.default.fileExists(atPath: $0)
    }) {
        self.fileExists = fileExists
    }

    func outputURL(
        for input: URL,
        outputContainer: MediaContainer? = nil
    ) -> URL {
        let directory = input.deletingLastPathComponent()
        let stem = input.deletingPathExtension().lastPathComponent
        let outputExtension = outputContainer?.preferredExtension
            ?? (input.pathExtension.isEmpty ? "wav" : input.pathExtension.lowercased())
        let first = directory.appendingPathComponent("\(stem).enhanced.\(outputExtension)")
        guard fileExists(first.path) else { return first }

        var index = 2
        while true {
            let candidate = directory.appendingPathComponent(
                "\(stem).enhanced-\(index).\(outputExtension)"
            )
            if !fileExists(candidate.path) { return candidate }
            index += 1
        }
    }
}
