import Foundation

/// Brute-force guard. After `maxFailures` bad keys within `window` the client is locked out for `lockout`
/// seconds; while locked even a correct key is refused (fail closed).
/// The client is the peer IP (normalised): one computer on the LAN being locked out does not affect the others.
/// Behind a tunnel on this machine every caller still shares the loopback address and is locked out together.
public final class AuthFailureLimiter {
    private let maxFailures: Int
    private let window: TimeInterval
    private let lockout: TimeInterval
    private let now: () -> Date
    private var failures: [String: [Date]] = [:]
    private var lockedUntil: [String: Date] = [:]
    private let lock = NSLock()

    public init(maxFailures: Int = 5, window: TimeInterval = 60, lockout: TimeInterval = 60,
                now: @escaping () -> Date = Date.init) {
        self.maxFailures = maxFailures
        self.window = window
        self.lockout = lockout
        self.now = now
    }

    /// Seconds until the client may try again, or nil when it is not locked out.
    public func retryAfter(client: String) -> TimeInterval? {
        lock.lock(); defer { lock.unlock() }
        guard let until = lockedUntil[client] else { return nil }
        let remaining = until.timeIntervalSince(now())
        if remaining > 0 { return remaining }
        lockedUntil[client] = nil
        failures[client] = nil
        return nil
    }

    public func recordFailure(client: String) {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        var recent = (failures[client] ?? []).filter { time.timeIntervalSince($0) < window }
        recent.append(time)
        failures[client] = recent
        if recent.count >= maxFailures { lockedUntil[client] = time.addingTimeInterval(lockout) }
        // Never let an attacker grow the table without bound.
        if failures.count > 1024 { failures = failures.filter { lockedUntil[$0.key] != nil } }
    }

    public func recordSuccess(client: String) {
        lock.lock(); defer { lock.unlock() }
        failures[client] = nil
    }
}

/// Sliding-window request limit per key (an API key id or a client address). The table is bounded.
public final class RequestRateLimiter {
    public static let maxTrackedKeys = 1024

    private let limit: Int
    private let window: TimeInterval
    private let now: () -> Date
    private var hits: [String: [Date]] = [:]
    private var lastPurge: Date?
    private let lock = NSLock()

    public init(limit: Int = 240, window: TimeInterval = 60, now: @escaping () -> Date = Date.init) {
        self.limit = limit
        self.window = window
        self.now = now
    }

    public var retryAfterSeconds: Int { max(1, Int(window.rounded(.up))) }

    var trackedKeyCount: Int { lock.lock(); defer { lock.unlock() }; return hits.count }

    public func allow(key: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        let time = now()
        purgeIfNeeded(time)
        var recent = (hits[key] ?? []).filter { time.timeIntervalSince($0) < window }
        guard recent.count < limit else { hits[key] = recent; return false }
        recent.append(time)
        hits[key] = recent
        return true
    }

    /// Drops expired entries once per window, and whenever the table is full. If it is still full, the least recently
    /// active keys go first, so an attacker inventing keys cannot grow the table without bound.
    private func purgeIfNeeded(_ time: Date) {
        let due = lastPurge.map { time.timeIntervalSince($0) >= window } ?? false
        guard due || hits.count >= RequestRateLimiter.maxTrackedKeys else { if lastPurge == nil { lastPurge = time }; return }
        lastPurge = time
        hits = hits.filter { entry in entry.value.contains { time.timeIntervalSince($0) < window } }
        if hits.count >= RequestRateLimiter.maxTrackedKeys {
            let oldestFirst = hits.sorted { ($0.value.last ?? .distantPast) < ($1.value.last ?? .distantPast) }
            for entry in oldestFirst.prefix(hits.count - RequestRateLimiter.maxTrackedKeys + 1) { hits[entry.key] = nil }
        }
    }
}
