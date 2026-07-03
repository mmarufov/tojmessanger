import XCTest
@testable import Toj

final class BackoffPolicyTests: XCTestCase {
    /// Deterministic "jitter": always the maximum, so delays are exactly the exponential.
    private let maxJitter: (Double) -> Double = { $0 }

    func testDelaysGrowExponentiallyAndCap() {
        var policy = BackoffPolicy(base: 0.5, cap: 30)
        var delays: [TimeInterval] = []
        for _ in 0..<10 {
            delays.append(policy.nextDelay(jitter: maxJitter))
        }
        XCTAssertEqual(delays[0], 0.5, accuracy: 0.001)
        XCTAssertEqual(delays[1], 1.0, accuracy: 0.001)
        XCTAssertEqual(delays[2], 2.0, accuracy: 0.001)
        XCTAssertEqual(delays[9], 30.0, accuracy: 0.001, "must cap, never grow unbounded")
    }

    func testJitterStaysWithinHalfToFullExponential() {
        var policy = BackoffPolicy(base: 0.5, cap: 30)
        for _ in 0..<50 {
            let before = policy
            let delay = policy.nextDelay()
            var reference = before
            let maxDelay = reference.nextDelay(jitter: maxJitter)
            XCTAssertGreaterThanOrEqual(delay, maxDelay / 2)
            XCTAssertLessThanOrEqual(delay, maxDelay)
        }
    }

    func testResetRestartsTheSchedule() {
        var policy = BackoffPolicy(base: 0.5, cap: 30)
        _ = policy.nextDelay(jitter: maxJitter)
        _ = policy.nextDelay(jitter: maxJitter)
        policy.reset()
        XCTAssertEqual(policy.nextDelay(jitter: maxJitter), 0.5, accuracy: 0.001)
    }
}
