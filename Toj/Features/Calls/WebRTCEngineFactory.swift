import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

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

    /// Profile 2 is advertised only when the pinned artifact exposes H264 on both sides and the
    /// transceiver codec-preference API used to prevent an unauthenticated codec fallback.
    nonisolated static var supportsCameraVideoProfile: Bool {
        #if canImport(WebRTC)
        let encoders = RTCDefaultVideoEncoderFactory().supportedCodecs()
        let decoders = RTCDefaultVideoDecoderFactory().supportedCodecs()
        let isCompatibleH264: (RTCVideoCodecInfo) -> Bool = { codec in
            guard codec.name.caseInsensitiveCompare("H264") == .orderedSame,
                  codec.parameters["packetization-mode"] == "1",
                  codec.parameters["level-asymmetry-allowed"] == "1"
            else { return false }
            let profile = codec.parameters["profile-level-id"]?.lowercased() ?? ""
            return profile.hasPrefix("640c") || profile.hasPrefix("42e0")
        }
        let hasEncoder = encoders.contains(where: isCompatibleH264)
        let hasDecoder = decoders.contains(where: isCompatibleH264)
        return hasEncoder && hasDecoder
            && RTCRtpTransceiver.instancesRespond(to: NSSelectorFromString("setCodecPreferences:error:"))
        #else
        return false
        #endif
    }

    nonisolated static var deviceCapabilities: CallDeviceCapabilities {
        CallDeviceCapabilities(
            supportedCallProtocolVersions: CallProtocolVersion.supported,
            supportedCallMediaProfileVersions: supportsCameraVideoProfile ? [1, 2] : [1],
            callViewVersion: supportsCameraVideoProfile ? 2 : 1
        )
    }

    static func production() -> any WebRTCEngine {
        #if canImport(WebRTC)
        WebRTCCallEngine()
        #else
        UnavailableWebRTCEngine()
        #endif
    }
}
