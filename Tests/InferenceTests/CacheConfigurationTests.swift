// SPDX-License-Identifier: Apache-2.0

import XCTest
@testable import Inference

final class CacheConfigurationTests: XCTestCase {
    func testCacheLimitDefaultsToTwoGiB() {
        XCTAssertEqual(MambaEnhancer.cacheLimitBytes(environment: [:]), 2_048 * 1_024 * 1_024)
    }

    func testCacheLimitSupportsDisableAndMLXDefaultModes() {
        XCTAssertEqual(
            MambaEnhancer.cacheLimitBytes(environment: ["SPEECHLENS_CACHE_LIMIT_MB": "0"]),
            0
        )
        XCTAssertNil(
            MambaEnhancer.cacheLimitBytes(environment: ["SPEECHLENS_CACHE_LIMIT_MB": "-1"])
        )
    }

    func testInvalidCacheLimitUsesDefault() {
        XCTAssertEqual(
            MambaEnhancer.cacheLimitBytes(environment: ["SPEECHLENS_CACHE_LIMIT_MB": "invalid"]),
            2_048 * 1_024 * 1_024
        )
    }
}
