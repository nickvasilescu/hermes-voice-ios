/// A minimal async mutual-exclusion lock. Actors already serialize access
/// to their own state, but `SessionCoordinator` needs to serialize a
/// sequence of *awaits* spanning multiple actor hops (mint credential →
/// connect transport → handshake) so that `start`/`rotate`/reconnect can
/// never interleave and stomp on each other's notion of "the" primary
/// transport. That's exactly what this buys, with no `@unchecked Sendable`
/// needed: it's an actor, so its own `locked`/`waiters` state is
/// provably race-free. [IMPLEMENTED]
actor AsyncMutex {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func withLock<T>(_ body: () async -> T) async -> T {
        await lock()
        let result = await body()
        unlock()
        return result
    }

    private func lock() async {
        if !locked {
            locked = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func unlock() {
        if waiters.isEmpty {
            locked = false
        } else {
            waiters.removeFirst().resume()
        }
    }
}
