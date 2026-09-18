// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Inference

final class StreamingSessionTests: XCTestCase {
    func testArbitraryAppendBoundariesPreserveIdentityAndFrameCount() async throws {
        let enhancer = IdentityWindowEnhancer()
        let session = try MambaEnhancementSession(
            enhancer: enhancer,
            sampleRate: 10,
            settings: InferenceSettings(chunkSeconds: 1, overlapPortion: 0)
        )
        let input = (0..<37).map(Float.init)
        var output = [Float]()
        for range in [0..<3, 3..<7, 7..<19, 19..<37] {
            output.append(contentsOf: try await session.append(Array(input[range])))
        }
        output.append(contentsOf: try await session.finish())

        XCTAssertEqual(output, input)
        let windowSizes = await enhancer.windowSizes()
        XCTAssertEqual(windowSizes, [10, 10, 10, 7])
    }

    func testOverlapAddPreservesIdentityAcrossExactAndPartialWindows() async throws {
        let enhancer = IdentityWindowEnhancer()
        let settings = try InferenceSettings(chunkSeconds: 1, overlapPortion: 0.25)
        let session = try MambaEnhancementSession(
            enhancer: enhancer,
            sampleRate: 12,
            settings: settings
        )
        let input = (0..<41).map { Float($0) / 41 }
        var output = [Float]()
        var offset = 0
        while offset < input.count {
            let end = min(input.count, offset + session.recommendedInputFrameCount)
            output.append(contentsOf: try await session.append(Array(input[offset..<end])))
            offset = end
        }
        output.append(contentsOf: try await session.finish())

        XCTAssertEqual(output.count, input.count)
        for index in input.indices {
            XCTAssertEqual(output[index], input[index], accuracy: 1e-6)
        }
    }

    func testEmptySessionFinishesEmpty() async throws {
        let session = try MambaEnhancementSession(
            enhancer: IdentityWindowEnhancer(),
            sampleRate: 16_000,
            settings: .standard
        )
        let output = try await session.finish()
        XCTAssertEqual(output, [])
    }

    func testFinishedSessionRejectsFurtherUse() async throws {
        let session = try MambaEnhancementSession(
            enhancer: IdentityWindowEnhancer(),
            sampleRate: 10,
            settings: try InferenceSettings(chunkSeconds: 1)
        )
        _ = try await session.append([1, 2, 3])
        _ = try await session.finish()
        await XCTAssertThrowsErrorAsync { _ = try await session.append([4]) }
        await XCTAssertThrowsErrorAsync { _ = try await session.finish() }
    }

    func testRejectsInvalidSampleRate() {
        XCTAssertThrowsError(
            try MambaEnhancementSession(
                enhancer: IdentityWindowEnhancer(),
                sampleRate: 0,
                settings: .standard
            )
        )
    }
}

private actor IdentityWindowEnhancer: MonoWindowEnhancing {
    private var sizes = [Int]()

    func enhanceWindow(_ samples: [Float], sampleRate: Int) -> [Float] {
        sizes.append(samples.count)
        return samples
    }

    func windowSizes() -> [Int] { sizes }
}

private func XCTAssertThrowsErrorAsync(
    _ expression: () async throws -> Void,
    file: StaticString = #filePath,
    line: UInt = #line
) async {
    do {
        try await expression()
        XCTFail("Expected error", file: file, line: line)
    } catch {}
}
