import Foundation

/// Privacy-preserving, low-cardinality call telemetry. Every value reported to the server is a
/// pinned bucket label or enumeration — never a raw measurement, key, address, or identifier — so
/// operators can track setup/recovery timing and media quality without any forbidden plaintext.
/// The bucket helpers are pure and deterministic so they can be verified with test vectors, and the
/// server independently re-validates every field it receives.
nonisolated enum CallTelemetry {
    static func timeBucket(_ seconds: Double?) -> String {
        guard let seconds, seconds >= 0 else { return "none" }
        if seconds <= 1 { return "le_1s" }
        if seconds <= 2 { return "le_2s" }
        if seconds <= 3 { return "le_3s" }
        if seconds <= 5 { return "le_5s" }
        return "gt_5s"
    }

    static func rttBucket(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return "none" }
        if milliseconds <= 100 { return "le_100" }
        if milliseconds <= 200 { return "le_200" }
        if milliseconds <= 400 { return "le_400" }
        if milliseconds <= 800 { return "le_800" }
        return "gt_800"
    }

    static func lossBucket(packetsLost: Int64?, packetsReceived: Int64?) -> String {
        guard let packetsLost, let packetsReceived,
              packetsLost >= 0, packetsReceived >= 0 else { return "none" }
        let total = packetsLost + packetsReceived
        guard total > 0 else { return "none" }
        let percent = Double(packetsLost) / Double(total) * 100
        if percent <= 1 { return "le_1" }
        if percent <= 5 { return "le_5" }
        if percent <= 10 { return "le_10" }
        if percent <= 20 { return "le_20" }
        return "gt_20"
    }

    static func jitterBucket(_ milliseconds: Double?) -> String {
        guard let milliseconds, milliseconds >= 0 else { return "none" }
        if milliseconds <= 10 { return "le_10" }
        if milliseconds <= 30 { return "le_30" }
        if milliseconds <= 60 { return "le_60" }
        return "gt_60"
    }

    static func bitrateBucket(bitsPerSecond: Double?) -> String {
        guard let bitsPerSecond, bitsPerSecond >= 0 else { return "none" }
        let kilobits = bitsPerSecond / 1_000
        if kilobits <= 16 { return "le_16" }
        if kilobits <= 24 { return "le_24" }
        if kilobits <= 32 { return "le_32" }
        if kilobits <= 48 { return "le_48" }
        return "gt_48"
    }

    static let appVersion: String? = {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
    }()

    /// Builds a fully bucketed report from raw call outcomes. `routeClass` and `region` are left to
    /// the caller because they are only known once the media engine or TURN edge can supply them.
    static func report(
        outcome: String,
        role: CallRole?,
        privacyMode: CallPrivacyMode,
        routeClass: String?,
        setupSeconds: Double?,
        recoverySeconds: Double?,
        recoveryCount: Int,
        stats: CallNetworkStats?,
        appVersion: String? = CallTelemetry.appVersion
    ) -> CallTelemetryRequest {
        CallTelemetryRequest(
            outcome: outcome,
            role: role?.rawValue,
            routeClass: routeClass,
            privacyMode: privacyMode.rawValue,
            setupBucket: timeBucket(setupSeconds),
            recoveryBucket: timeBucket(recoverySeconds),
            rttBucket: rttBucket(stats?.roundTripTimeMilliseconds),
            lossBucket: lossBucket(
                packetsLost: stats?.packetsLost,
                packetsReceived: stats?.packetsReceived
            ),
            jitterBucket: jitterBucket(stats?.jitterMilliseconds),
            bitrateBucket: bitrateBucket(bitsPerSecond: stats?.audioBitrate),
            recoveryCount: max(0, recoveryCount),
            appVersion: appVersion,
            region: nil
        )
    }
}
