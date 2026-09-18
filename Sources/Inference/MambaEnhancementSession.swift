// SPDX-License-Identifier: Apache-2.0

import Foundation

protocol MonoWindowEnhancing: Sendable {
    func enhanceWindow(_ samples: [Float], sampleRate: Int) async throws -> [Float]
}

extension MambaEnhancer: MonoWindowEnhancing {}

/// Bounded mono stream state. The shared `MambaEnhancer` actor performs every
/// model invocation, so sessions may coexist without concurrent model access.
actor MambaEnhancementSession: SpeechEnhancementSession {
    nonisolated let recommendedInputFrameCount: Int

    private let enhancer: any MonoWindowEnhancing
    private let sampleRate: Int
    private let chunkLength: Int
    private let overlapLength: Int
    private let stride: Int

    private var input = [Float]()
    private var accumulation = [Float]()
    private var normalization = [Float]()
    private var chunkIndex = 0
    private var isFinished = false

    init(
        enhancer: any MonoWindowEnhancing,
        sampleRate: Int,
        settings: InferenceSettings
    ) throws {
        guard sampleRate > 0 else {
            throw InferenceError.inferenceFailed("Sample rate must be greater than zero")
        }
        let chunkLengthDouble = settings.chunkSeconds * Double(sampleRate)
        guard chunkLengthDouble.isFinite,
              chunkLengthDouble >= 1,
              chunkLengthDouble < Double(Int.max) else {
            throw InferenceError.inferenceFailed(
                "Invalid chunk length from chunkSeconds=\(settings.chunkSeconds) and sampleRate=\(sampleRate)"
            )
        }

        let chunkLength = Int(chunkLengthDouble)
        let rawOverlap = Int(Double(chunkLength) * settings.overlapPortion)
        let overlapLength = max(0, min(chunkLength - 1, rawOverlap))
        let stride = max(1, chunkLength - overlapLength)

        self.enhancer = enhancer
        self.sampleRate = sampleRate
        self.chunkLength = chunkLength
        self.overlapLength = overlapLength
        self.stride = stride
        self.recommendedInputFrameCount = stride
    }

    func append(_ monoFrames: [Float]) async throws -> [Float] {
        guard !isFinished else {
            throw InferenceError.inferenceFailed("Cannot append to a finished enhancement session")
        }
        guard !monoFrames.isEmpty else { return [] }
        try Task.checkCancellation()
        input.append(contentsOf: monoFrames)

        var emitted = [Float]()
        while input.count >= chunkLength && input.count > stride {
            let window = Array(input.prefix(chunkLength))
            let enhanced = try await enhancer.enhanceWindow(window, sampleRate: sampleRate)
            try accumulate(enhanced, isLast: false)
            emitted.append(contentsOf: emitPrefix(stride))
            input.removeFirst(stride)
            chunkIndex += 1
            try Task.checkCancellation()
        }
        return emitted
    }

    func finish() async throws -> [Float] {
        guard !isFinished else {
            throw InferenceError.inferenceFailed("Enhancement session is already finished")
        }
        isFinished = true
        try Task.checkCancellation()

        if !input.isEmpty {
            let enhanced = try await enhancer.enhanceWindow(input, sampleRate: sampleRate)
            try accumulate(enhanced, isLast: true)
            input.removeAll(keepingCapacity: false)
            chunkIndex += 1
        }
        return emitPrefix(accumulation.count)
    }

    private func accumulate(_ enhanced: [Float], isLast: Bool) throws {
        guard !enhanced.isEmpty else { return }
        if accumulation.count < enhanced.count {
            accumulation.append(contentsOf: repeatElement(0, count: enhanced.count - accumulation.count))
            normalization.append(contentsOf: repeatElement(0, count: enhanced.count - normalization.count))
        }

        let effectiveOverlap = min(overlapLength, max(0, enhanced.count - 1))
        let isFirst = chunkIndex == 0
        // Corresponding fade-in and fade-out weights sum to one because
        // sin²(x) + cos²(x) = 1, preserving constant overlap-add gain.
        for index in enhanced.indices {
            var weight: Float = 1
            if effectiveOverlap > 0 {
                if index < effectiveOverlap && !isFirst {
                    let position = Float(index) / Float(effectiveOverlap)
                    let sine = Foundation.sin(Float.pi * 0.5 * position)
                    weight = sine * sine
                } else if index >= enhanced.count - effectiveOverlap && !isLast {
                    let position = Float(index - (enhanced.count - effectiveOverlap))
                        / Float(effectiveOverlap)
                    let cosine = Foundation.cos(Float.pi * 0.5 * position)
                    weight = cosine * cosine
                }
            }
            accumulation[index] += enhanced[index] * weight
            normalization[index] += weight
        }
    }

    private func emitPrefix(_ count: Int) -> [Float] {
        let emittedCount = min(count, accumulation.count)
        guard emittedCount > 0 else { return [] }

        var output = [Float](repeating: 0, count: emittedCount)
        for index in 0..<emittedCount where normalization[index] > 1e-8 {
            output[index] = accumulation[index] / normalization[index]
        }
        accumulation.removeFirst(emittedCount)
        normalization.removeFirst(emittedCount)
        return output
    }
}
