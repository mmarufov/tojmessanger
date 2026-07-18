import Foundation

/// Selects only a session that was not already marked for durable revocation by sign-out.
nonisolated enum CallLaunchSessionPolicy {
    static func session(
        from stored: StoredCloudSession?,
        pendingRevocationToken: String?
    ) -> CloudSession? {
        guard let stored, stored.session.token != pendingRevocationToken else { return nil }
        return stored.session
    }
}

/// Restores the minimum state needed to answer a PushKit/CallKit call when iOS launches Toj in the
/// background. Full messaging bootstrap remains owned by CloudAppModel once a SwiftUI scene exists.
@MainActor
final class CallProcessBootstrap {
    static let shared = CallProcessBootstrap()

    private let api: CloudAPI
    private let tokenStore: TokenStore
    private var task: Task<Void, Never>?

    init(config: CloudConfig = .current, tokenStore: TokenStore = TokenStore()) {
        api = CloudAPI(config: config)
        self.tokenStore = tokenStore
    }

    func start() {
        guard task == nil else { return }
        task = Task { [api, tokenStore] in
            do {
                let pendingRevocation = try await tokenStore.loadPendingRevocationToken()
                let stored = try await tokenStore.load()
                guard let session = CallLaunchSessionPolicy.session(
                    from: stored,
                    pendingRevocationToken: pendingRevocation
                ) else { return }
                CallCoordinator.shared.configure(api: api, session: session) { _, _ in
                    String(localized: "Toj caller")
                }
            } catch {
                // CallKit still receives and terminates the push correctly. If secure session
                // restoration is unavailable, answering fails closed instead of using stale auth.
            }
        }
    }
}
