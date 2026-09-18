// SPDX-License-Identifier: Apache-2.0

import Foundation
import Inference

/// Test-only convenience for collecting a bounded streaming session into a value.
public func collectEnhancedSamples(
    enhancer: any StreamingSpeechEnhancer,
    samples: [Float],
    sampleRate: Int,
    settings: InferenceSettings
) async throws -> [Float] {
    let session = try await enhancer.makeSession(sampleRate: sampleRate, settings: settings)
    let blockSize = session.recommendedInputFrameCount
    var output = [Float]()
    output.reserveCapacity(samples.count)
    var offset = 0
    while offset < samples.count {
        let end = min(samples.count, offset + blockSize)
        output.append(contentsOf: try await session.append(Array(samples[offset..<end])))
        offset = end
    }
    output.append(contentsOf: try await session.finish())
    return output
}
