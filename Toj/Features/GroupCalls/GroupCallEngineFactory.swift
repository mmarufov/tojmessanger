import Foundation

#if canImport(LiveKit)
@preconcurrency import LiveKit
#endif

#if !canImport(LiveKit) && !DEBUG
#error("Release builds require the attested LiveKit Swift package for encrypted group calls.")
#endif

@MainActor
enum GroupCallEngineFactory {
    nonisolated static let expectedSDKVersion = "2.13.0"
    nonisolated static let appGroupIdentifier = "group.com.toj.Toj"
    nonisolated static let broadcastExtensionIdentifier = "com.toj.Toj.broadcast"

    nonisolated private static let runtimeProbe: Bool = {
        #if canImport(LiveKit)
        guard LiveKitSDK.version == expectedSDKVersion else { return false }
        let options = KeyProviderOptions(
            sharedKey: true,
            ratchetWindowSize: 0,
            uncryptedMagicBytes: Data(),
            failureTolerance: -1,
            keyRingSize: 16
        )
        guard options.uncryptedMagicBytes.isEmpty else { return false }
        let provider = BaseKeyProvider(options: options)
        let probe = Data(repeating: 0xA5, count: 32).base64EncodedString()
        let probeIndex: Int32 = 1
        provider.setKey(key: probe, index: probeIndex)
        provider.setCurrentKeyIndex(probeIndex)
        guard provider.getCurrentKeyIndex() == probeIndex,
              provider.exportKey(index: probeIndex) == Data(probe.utf8) else { return false }
        _ = E2EEOptions(keyProvider: provider, encryptionType: .gcm)
        return true
        #else
        return false
        #endif
    }()

    nonisolated static var isAvailable: Bool { runtimeProbe }

    nonisolated private static let screenShareProbe: Bool = {
        guard runtimeProbe else { return false }
        #if targetEnvironment(simulator)
        return false
        #else
        guard FileManager.default.containerURL(
            forSecurityApplicationGroupIdentifier: appGroupIdentifier
        ) != nil else { return false }
        let extensionURL = Bundle.main.builtInPlugInsURL?
            .appending(path: "TojBroadcastExtension.appex", directoryHint: .notDirectory)
        guard let extensionURL,
              let bundle = Bundle(url: extensionURL),
              bundle.bundleIdentifier == broadcastExtensionIdentifier else { return false }
        return true
        #endif
    }()

    nonisolated static var supportsScreenShare: Bool { screenShareProbe }

    nonisolated static var deviceCapabilities: GroupCallDeviceCapabilities {
        guard isAvailable else { return .legacy }
        return GroupCallDeviceCapabilities(
            supportedGroupCallVersions: [1],
            groupCallViewVersion: 1,
            supportsGroupScreenShare: supportsScreenShare
        )
    }

    static func production() -> any GroupCallMediaEngine {
        #if canImport(LiveKit)
        guard isAvailable else { return UnavailableGroupCallEngine() }
        return LiveKitGroupCallEngine()
        #else
        return UnavailableGroupCallEngine()
        #endif
    }
}
