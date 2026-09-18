// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Immutable identity and provenance for a model artifact trusted by the app.
struct ModelArtifactDescriptor: Sendable, Equatable {
    let version: String
    let revision: String
    let expectedSHA256: String
    let expectedSizeBytes: Int64
    let sourceModelURL: URL
    let convertedWeightsURL: URL
    let licenseURL: URL
    let manifestURL: URL
    let modelDownloadURL: URL

    static let current = Self(
        version: "1.0.0",
        revision: "07bc44c152c5f9f665d2474cf1f5b69edc7cae14",
        expectedSHA256: "d1158502eaf39d0b11d097177160ce3804454653c5d14d17921b6c274ca53237",
        expectedSizeBytes: 38_583_628,
        sourceModelURL: URL(string: "https://huggingface.co/nvidia/RE-USE")!,
        convertedWeightsURL: URL(string: "https://huggingface.co/faraday/re-use-mlx")!,
        licenseURL: URL(string: "https://huggingface.co/faraday/re-use-mlx/blob/main/LICENSE")!,
        manifestURL: URL(
            string: "https://huggingface.co/faraday/re-use-mlx/resolve/07bc44c152c5f9f665d2474cf1f5b69edc7cae14/conversion-manifest.json"
        )!,
        modelDownloadURL: URL(
            string: "https://huggingface.co/faraday/re-use-mlx/resolve/07bc44c152c5f9f665d2474cf1f5b69edc7cae14/model_mlx.safetensors"
        )!
    )
}
