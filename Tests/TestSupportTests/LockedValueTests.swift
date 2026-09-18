// SPDX-License-Identifier: Apache-2.0

import TestSupport
import XCTest

final class LockedValueTests: XCTestCase {
    func testMutatesAndReadsSynchronousCallbackState() {
        let value = LockedValue([Int]())
        value.withValue { $0.append(contentsOf: [1, 2, 3]) }
        XCTAssertEqual(value.read(), [1, 2, 3])
    }
}
