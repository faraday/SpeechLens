// SPDX-License-Identifier: Apache-2.0

import CryptoKit
import Diagnostics
import Foundation

struct ModelArtifactRepository {
    let fileManager: FileManager

    func evaluateState(
        weightsURL: URL,
        manifestURL: URL,
        descriptor: ModelArtifactDescriptor
    ) -> ModelSetupState {
        guard fileManager.fileExists(atPath: weightsURL.path) else {
            return .missing
        }
        guard fileManager.fileExists(atPath: manifestURL.path) else {
            return .failed(ModelSetupFailure(
                code: .modelCacheManifestMissing,
                technicalDetail: "Cached model manifest is missing. Download the model again."
            ))
        }

        do {
            let manifestData = try Data(contentsOf: manifestURL)
            let manifestSHA = try ModelArtifactVerifier.expectedModelSHA256(from: manifestData)
            guard manifestSHA.caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame else {
                return .failed(ModelSetupFailure(
                    code: .modelCacheManifestMismatch,
                    technicalDetail: "Cached model manifest does not match the pinned artifact."
                ))
            }
            let actualSHA = try ModelArtifactVerifier.sha256Hex(forFileAt: weightsURL)
            guard actualSHA.caseInsensitiveCompare(descriptor.expectedSHA256) == .orderedSame else {
                return .failed(ModelSetupFailure(
                    code: .modelCacheChecksumMismatch,
                    technicalDetail: "Cached model failed checksum. Download it again."
                ))
            }
            return .ready
        } catch {
            return .failed(ModelSetupFailure(
                code: .modelCacheVerificationFailed,
                technicalDetail: "Cached model could not be verified. Download it again."
            ))
        }
    }

    func prepareStagingDirectory(cacheDirectoryURL: URL, stagingURL: URL) throws {
        try fileManager.createDirectory(
            at: cacheDirectoryURL,
            withIntermediateDirectories: true
        )
        removeIfPresent(stagingURL)
    }

    func moveDownloadedFile(_ downloadedURL: URL, to stagingURL: URL) throws {
        try fileManager.moveItem(at: downloadedURL, to: stagingURL)
    }

    func installVerifiedModel(
        from stagingURL: URL,
        manifestData: Data,
        weightsURL: URL,
        manifestURL: URL
    ) throws {
        if fileManager.fileExists(atPath: weightsURL.path) {
            _ = try fileManager.replaceItemAt(weightsURL, withItemAt: stagingURL)
        } else {
            try fileManager.moveItem(at: stagingURL, to: weightsURL)
        }
        try manifestData.write(to: manifestURL, options: .atomic)
    }

    func removeIfPresent(_ url: URL) {
        try? fileManager.removeItem(at: url)
    }
}

enum ModelArtifactVerifier {
    static func expectedModelSHA256(from manifestData: Data) throws -> String {
        let object = try JSONSerialization.jsonObject(with: manifestData)
        guard let manifest = object as? [String: Any] else {
            throw ModelStoreError.invalidManifest
        }

        for key in ["model_sha256", "sha256", "checksum"] {
            if let value = manifest[key] as? String, value.count >= 32 {
                return value.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        if let model = manifest["model_mlx.safetensors"] as? [String: Any],
           let sha = shaValue(in: model) {
            return sha
        }
        if let files = manifest["files"] as? [[String: Any]] {
            for file in files {
                let name = (file["name"] as? String)
                    ?? (file["path"] as? String)
                    ?? (file["filename"] as? String)
                    ?? ""
                if name.contains("model_mlx.safetensors"), let sha = shaValue(in: file) {
                    return sha
                }
            }
        }
        if let files = manifest["files"] as? [String: Any],
           let model = files["model_mlx.safetensors"] as? [String: Any],
           let sha = shaValue(in: model) {
            return sha
        }
        throw ModelStoreError.missingChecksum
    }

    static func sha256Hex(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func sha256Hex(forFileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let data = try handle.read(upToCount: 1024 * 1024) ?? Data()
            if data.isEmpty { break }
            hasher.update(data: data)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func shaValue(in dictionary: [String: Any]) -> String? {
        for key in ["sha256", "checksum", "digest"] {
            if let value = dictionary[key] as? String, value.count >= 32 {
                return value
                    .replacingOccurrences(of: "sha256:", with: "")
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return nil
    }
}

enum ModelStoreError: Error {
    case invalidManifest
    case missingChecksum
    case manifestChecksumMismatch
    case checksumMismatch
    case missingDownloadedFile
    case httpStatus(Int, String)

    var message: String {
        switch self {
        case .invalidManifest:
            return "Manifest is not valid JSON."
        case .missingChecksum:
            return "Manifest is missing the model checksum."
        case .manifestChecksumMismatch:
            return "Manifest does not match the pinned model checksum."
        case .checksumMismatch:
            return "Downloaded model did not match the pinned checksum."
        case .missingDownloadedFile:
            return "Downloaded model file was not available."
        case .httpStatus(let status, let file):
            return "\(file) returned HTTP \(status)."
        }
    }

    var failureCode: DiagnosticFailureCode {
        switch self {
        case .invalidManifest: return .modelDownloadInvalidManifest
        case .missingChecksum: return .modelDownloadMissingChecksum
        case .manifestChecksumMismatch: return .modelDownloadManifestMismatch
        case .checksumMismatch: return .modelDownloadChecksumMismatch
        case .missingDownloadedFile: return .modelDownloadMissingFile
        case .httpStatus: return .modelDownloadHTTPStatus
        }
    }
}
