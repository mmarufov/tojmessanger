import Foundation

/// Where the dev relay lives. Defaults to localhost (simulators); override with
/// the TOJ_SERVER_HOST / TOJ_SERVER_TLS environment variables or edit `current`
/// when pointing physical devices at the VPS.
nonisolated struct SkeletonConfig: Sendable {
    var httpBase: URL
    var wsBase: URL

    static var current: SkeletonConfig {
        let env = ProcessInfo.processInfo.environment
        // The relay endpoint is injected at run time via TOJ_SERVER_HOST / TOJ_SERVER_TLS
        // (Xcode scheme env vars for devices, SIMCTL_CHILD_* for simulators). Server
        // endpoints are deliberately NOT hardcoded here — infrastructure is kept out of
        // the public repo.
        #if targetEnvironment(simulator)
        let deviceDefaultTLS = false
        #else
        let deviceDefaultTLS = true   // physical devices talk to a real relay over TLS
        #endif
        let host = env["TOJ_SERVER_HOST"] ?? "127.0.0.1:8787"
        let isLoopback = host.hasPrefix("127.") || host.hasPrefix("localhost")
        let tls = env["TOJ_SERVER_TLS"].map { $0 == "1" } ?? (isLoopback ? false : deviceDefaultTLS)
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
