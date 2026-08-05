import LiveKit

/// ReplayKit upload handler. LiveKit moves encoded samples over the application-group socket;
/// the main app remains the only process that publishes an encrypted screen-share RTP track.
final class SampleHandler: LKSampleHandler, @unchecked Sendable {}
