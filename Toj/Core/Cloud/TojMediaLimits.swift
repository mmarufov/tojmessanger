import Foundation

/// One source of truth for message-media limits on iOS.
///
/// The transfer engine is offset/part based, so a 100 MB object remains resumable on hostile
/// networks. Keeping this below the server's configurable hard ceiling also bounds temporary disk
/// use and the few picker paths that still need to inspect an asset before it is encrypted.
nonisolated enum TojMediaLimits {
    static let maximumMessageBytes: Int64 = 100 * 1024 * 1024
    static let maximumMessageBytesInt = Int(maximumMessageBytes)
    static let displayMaximum = "100 MB"
}
