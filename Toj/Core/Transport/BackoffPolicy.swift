import Foundation

/// Exponential backoff with full jitter (delay drawn from [exp/2, exp)).
/// Jitter is injectable so tests stay deterministic.
nonisolated struct BackoffPolicy: Sendable {
    var base: TimeInterval = 0.5
    var cap: TimeInterval = 30
    private(set) var attempt: Int = 0

    mutating func nextDelay(jitter: (Double) -> Double = { Double.random(in: 0..<$0) }) -> TimeInterval {
        let exponential = min(cap, base * pow(2, Double(attempt)))
        attempt += 1
        return exponential / 2 + jitter(exponential / 2)
    }

    mutating func reset() {
        attempt = 0
    }
}
