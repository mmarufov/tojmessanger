import Foundation

/// Selects only a session that is not fenced by durable revocation, erasure, or reauthentication.
nonisolated enum CallLaunchSessionPolicy {
    static func session(
        from stored: StoredCloudSession?,
        pendingRevocationToken: String?
    ) -> CloudSession? {
        session(
            from: stored,
            pendingRevocationTokens: pendingRevocationToken.map { [$0] } ?? []
        )
    }

    static func session(
        from stored: StoredCloudSession?,
        pendingRevocationTokens: [String]
    ) -> CloudSession? {
        guard let stored, !pendingRevocationTokens.contains(stored.session.token) else { return nil }
        return stored.session
    }

    static func session(
        from stored: StoredCloudSession?,
        pendingRevocations: [PendingSessionRevocation],
        hasPendingLocalErasure: Bool,
        pendingReauthenticationAccountId: String? = nil
    ) -> CloudSession? {
        guard case .restoreSavedSession = PendingRevocationLaunchPolicy.action(
            savedSession: stored,
            pendingRevocations: pendingRevocations,
            hasPendingLocalErasure: hasPendingLocalErasure,
            pendingReauthenticationAccountId: pendingReauthenticationAccountId
        ) else { return nil }
        return stored?.session
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
                let pendingRevocations = try await tokenStore.loadPendingRevocations()
                let pendingLocalErasure = try await tokenStore.hasPendingLocalErasure()
                let pendingReauthentication = try await tokenStore
                    .loadPendingReauthenticationAccountId()
                let stored = try await tokenStore.load()
                guard let session = CallLaunchSessionPolicy.session(
                    from: stored,
                    pendingRevocations: pendingRevocations,
                    hasPendingLocalErasure: pendingLocalErasure,
                    pendingReauthenticationAccountId: pendingReauthentication
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
