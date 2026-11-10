import Foundation

// Nacho Pet — ported from nacho-gadget-app Core (PR #1 @1d685fa).

/// Exponential backoff for `/ws/chat` reconnects. Jitter is injected so tests are deterministic.
public struct ReconnectPolicy: Equatable {
    public var baseDelay: TimeInterval = 1
    public var maxDelay: TimeInterval = 30
    public var maxAttempts: Int = 8

    public init(baseDelay: TimeInterval = 1, maxDelay: TimeInterval = 30, maxAttempts: Int = 8) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.maxAttempts = maxAttempts
    }

    /// `attempt` starts at 1. `jitter` in 0...1 scales the delay into [50%, 100%].
    public func delay(attempt: Int, jitter: Double = 1) -> TimeInterval {
        let a = max(1, min(attempt, 30))
        let raw = min(maxDelay, baseDelay * pow(2, Double(a - 1)))
        let j = min(1, max(0, jitter))
        return raw * (0.5 + 0.5 * j)
    }

    public func shouldRetry(attempt: Int, failure: TransportFailure) -> Bool {
        if failure.httpStatus == 401 || failure.httpStatus == 403 { return false }  // auth problem: retrying cannot help
        return attempt <= maxAttempts
    }
}

public struct TransportFailure: Equatable, Error {
    public var httpStatus: Int?
    public var message: String
    public init(httpStatus: Int? = nil, message: String) {
        self.httpStatus = httpStatus
        self.message = message
    }
}
