import Foundation

/// One source of truth for message-media limits on iOS.
///
/// The transfer engine is offset/part based, but picker and encryption paths still materialize
/// complete objects. Keep the public ceiling at 25 MB until those paths stream from files and the
/// server moves media payloads out of PostgreSQL.
nonisolated enum TojMediaLimits {
    static let maximumMessageBytes: Int64 = 25 * 1024 * 1024
    static let maximumMessageBytesInt = Int(maximumMessageBytes)
    static let displayMaximum = "25 MB"
}
