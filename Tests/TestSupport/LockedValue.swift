// SPDX-License-Identifier: Apache-2.0

import Foundation

/// Test-only storage for synchronous `@Sendable` callbacks that cannot await
/// an actor. Production code should continue to prefer actor isolation.
public final class LockedValue<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ value: Value) {
        self.value = value
    }

    public func read() -> Value {
        lock.withLock { value }
    }

    @discardableResult
    public func withValue<Result>(_ body: (inout Value) throws -> Result) rethrows -> Result {
        try lock.withLock { try body(&value) }
    }
}
