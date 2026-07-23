import Foundation
import Observation

@MainActor
@Observable
final class CallPrivacyPreferences {
    static let shared = CallPrivacyPreferences()

    private static let hideIPAddressKey = "toj.calls.hide_ip_address"
    private static let dataUsagePolicyKey = "toj.calls.video_data_usage_policy"
    private let defaults: UserDefaults

    var hidesIPAddress: Bool {
        didSet { defaults.set(hidesIPAddress, forKey: Self.hideIPAddressKey) }
    }

    var dataUsagePolicy: CallDataUsagePolicy {
        didSet { defaults.set(dataUsagePolicy.rawValue, forKey: Self.dataUsagePolicyKey) }
    }

    var mode: CallPrivacyMode {
        hidesIPAddress ? .relayOnly : .fastestRoute
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hidesIPAddress = defaults.bool(forKey: Self.hideIPAddressKey)
        dataUsagePolicy = defaults.string(forKey: Self.dataUsagePolicyKey)
            .flatMap(CallDataUsagePolicy.init(rawValue:)) ?? .cellularOnly
    }
}
