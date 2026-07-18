import Foundation

#if !canImport(WebRTC) && !DEBUG
#error("Release builds require the pinned WebRTC XCFramework. Run scripts/fetch-webrtc-xcframework.sh first.")
#endif

/// The integration point for the pinned WebRTC XCFramework. Builds that have not fetched the
/// artifact fail closed instead of pretending a call connected.
@MainActor
enum WebRTCEngineFactory {
    nonisolated static var isAvailable: Bool {
        #if canImport(WebRTC)
        true
        #else
        false
        #endif
    }

    static func production() -> any WebRTCEngine {
        #if canImport(WebRTC)
        WebRTCVoiceEngine()
        #else
        UnavailableWebRTCEngine()
        #endif
    }
}
