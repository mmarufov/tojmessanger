import Foundation

nonisolated enum CloudConfigValidationIssue: Equatable, Sendable {
    case insecureReleaseEndpoint
    case loopbackOnPhysicalDevice

    var message: String {
        switch self {
        case .insecureReleaseEndpoint:
            "The cloud endpoint must use HTTPS in release builds."
        case .loopbackOnPhysicalDevice:
            "This iPhone is configured to connect to itself instead of the Toj server."
        }
    }
}

nonisolated struct CloudConfig: Sendable {
    var baseURL: URL

    static var current: CloudConfig {
        resolve(environment: ProcessInfo.processInfo.environment, defaults: .standard)
    }

    static func resolve(environment: [String: String], defaults: UserDefaults) -> CloudConfig {
        if let raw = environment["TOJ_CLOUD_BASE_URL"], let url = URL(string: raw) {
            defaults.set(raw, forKey: "TOJ_CLOUD_BASE_URL")
            return CloudConfig(baseURL: url)
        }
        if let raw = defaults.string(forKey: "TOJ_CLOUD_BASE_URL"), let url = URL(string: raw) {
            return CloudConfig(baseURL: url)
        }
        return CloudConfig(baseURL: URL(string: "http://127.0.0.1:8788")!)
    }

    func httpURL(path: String) -> URL {
        baseURL.appending(path: path)
    }

    func wsURL() -> URL {
        var components = URLComponents(url: httpURL(path: "v1/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        return components.url!
    }

    func validationIssue(environment: [String: String] = ProcessInfo.processInfo.environment) -> CloudConfigValidationIssue? {
        #if !DEBUG
        guard baseURL.scheme?.lowercased() == "https" else {
            return .insecureReleaseEndpoint
        }
        #endif

        let host = baseURL.host?.lowercased() ?? ""
        let isLoopback = host == "localhost" || host == "127.0.0.1" || host == "::1"
        guard isLoopback else { return nil }
        let isSimulator = environment["SIMULATOR_UDID"] != nil
            || environment["SIMULATOR_DEVICE_NAME"] != nil
        let explicitlyAllowed = environment["TOJ_ALLOW_LOOPBACK"] == "1"
        return isSimulator || explicitlyAllowed ? nil : .loopbackOnPhysicalDevice
    }
}
