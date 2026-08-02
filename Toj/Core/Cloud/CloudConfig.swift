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
    private static let defaultsKey = "TOJ_CLOUD_BASE_URL"
    private static let bundledURLKey = "TOJCloudBaseURL"

    var baseURL: URL

    static var current: CloudConfig {
        resolve(
            environment: ProcessInfo.processInfo.environment,
            defaults: .standard,
            bundledBaseURL: Bundle.main.object(forInfoDictionaryKey: bundledURLKey) as? String
        )
    }

    static func resolve(
        environment: [String: String],
        defaults: UserDefaults,
        bundledBaseURL: String? = nil
    ) -> CloudConfig {
        if let raw = environment[defaultsKey], let url = validBaseURL(raw) {
            defaults.set(raw, forKey: defaultsKey)
            return CloudConfig(baseURL: url)
        }

        // A signed Release build must win over an endpoint persisted by a previous
        // developer launch. Debug builds leave this Info.plist value empty, so their
        // environment override still survives a manual relaunch.
        if let bundledBaseURL, let url = validBaseURL(bundledBaseURL) {
            return CloudConfig(baseURL: url)
        }

        if let raw = defaults.string(forKey: defaultsKey), let url = validBaseURL(raw) {
            return CloudConfig(baseURL: url)
        }
        return CloudConfig(baseURL: URL(string: "http://127.0.0.1:8788")!)
    }

    private static func validBaseURL(_ raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              url.host != nil else { return nil }
        return url
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
