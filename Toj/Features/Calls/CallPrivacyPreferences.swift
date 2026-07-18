import Foundation
import Observation

@MainActor
@Observable
final class CallPrivacyPreferences {
    static let shared = CallPrivacyPreferences()

    private static let hideIPAddressKey = "toj.calls.hide_ip_address"
    private let defaults: UserDefaults

    var hidesIPAddress: Bool {
        didSet { defaults.set(hidesIPAddress, forKey: Self.hideIPAddressKey) }
    }

    var mode: CallPrivacyMode {
        hidesIPAddress ? .relayOnly : .fastestRoute
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidesIPAddress = defaults.bool(forKey: Self.hideIPAddressKey)
    }
}
