import Foundation

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

    func wsURL(token: String) -> URL {
        var components = URLComponents(url: httpURL(path: "v1/ws"), resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url!
    }
}
