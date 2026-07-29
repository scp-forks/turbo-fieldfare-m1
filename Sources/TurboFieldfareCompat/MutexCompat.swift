import Foundation

/// macOS 14 backport shim for `Synchronization.Mutex`.
///
/// Upstream targets macOS 26 and uses `Mutex` from the Synchronization module,
/// which is only available on macOS 15 or newer. This checkout deploys to
/// macOS 14, so the standard-library type is unavailable.
///
/// This provides the subset of the `Mutex` surface the project actually uses —
/// construction from an initial value plus `withLock` / `withLockIfAvailable` —
/// backed by `NSLock`. Call sites are unchanged; only the `import` differs.
///
/// Differences from the standard-library type, none of which the project relies
/// on: this is a reference type rather than a `~Copyable` value type, and it
/// does not support a non-copyable `Value`.
public final class Mutex<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    public init(_ initialValue: Value) {
        self.value = initialValue
    }

    /// Run `body` with exclusive access to the protected value.
    public borrowing func withLock<Result>(
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    /// Run `body` only if the lock can be acquired without blocking.
    /// Returns `nil` when the lock is already held.
    public borrowing func withLockIfAvailable<Result>(
        _ body: (inout Value) throws -> Result
    ) rethrows -> Result? {
        guard lock.try() else { return nil }
        defer { lock.unlock() }
        return try body(&value)
    }
}
