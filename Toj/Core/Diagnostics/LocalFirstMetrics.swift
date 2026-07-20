import Foundation
import os

nonisolated enum LocalFirstMetrics {
    static let logger = Logger(subsystem: "com.toj.Toj", category: "LocalFirst")
    static let signposter = OSSignposter(subsystem: "com.toj.Toj", category: "LocalFirst")

    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name)
    }

    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    static func cacheResult(hit: Bool, thumbnail: Bool) {
        logger.debug("Media cache \(hit ? "hit" : "miss", privacy: .public), thumbnail: \(thumbnail, privacy: .public)")
    }

    static func presentationCacheTier(_ tier: String) {
        logger.debug("Media presentation tier: \(tier, privacy: .public)")
    }

    static func queueDepth(_ depth: Int) {
        logger.debug("Media queue depth: \(depth, privacy: .public)")
    }

    static func duration(_ name: String, since start: Date) {
        let milliseconds = max(0, Date().timeIntervalSince(start) * 1_000)
        logger.debug("\(name, privacy: .public): \(milliseconds, privacy: .public) ms")
    }
}
