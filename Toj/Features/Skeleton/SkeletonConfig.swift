import Foundation

/// Where the dev relay lives. Defaults to localhost (simulators); override with
/// the TOJ_SERVER_HOST / TOJ_SERVER_TLS environment variables or edit `current`
/// when pointing physical devices at the VPS.
nonisolated struct SkeletonConfig: Sendable {
    var httpBase: URL
    var wsBase: URL

    static var current: SkeletonConfig {
        let env = ProcessInfo.processInfo.environment
        let host = env["TOJ_SERVER_HOST"] ?? "127.0.0.1:8787"
        let tls = env["TOJ_SERVER_TLS"] == "1"
        return SkeletonConfig(
            httpBase: URL(string: "\(tls ? "https" : "http")://\(host)")!,
            wsBase: URL(string: "\(tls ? "wss" : "ws")://\(host)")!
        )
    }

    func wsURL(user: String) -> URL {
        var components = URLComponents(url: wsBase.appending(path: "v1/ws"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "user", value: user)]
        return components.url!
    }
}
