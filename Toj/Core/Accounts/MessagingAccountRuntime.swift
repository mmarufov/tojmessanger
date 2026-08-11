import Foundation
import GRDB

nonisolated enum AccountSwitchBlocker: Equatable, Sendable {
    case activeCall
    case voiceRecording

    var explanation: String {
        switch self {
        case .activeCall:
            String(localized: "Finish the current call before switching accounts.")
        case .voiceRecording:
            String(localized: "Finish or cancel the voice recording before switching accounts.")
        }
    }
}

nonisolated enum MessagingAccountRuntimeError: LocalizedError, Sendable {
    case fenced
    case switchBlocked(AccountSwitchBlocker)
    case accountNotReady

    var errorDescription: String? {
        switch self {
        case .fenced:
            "This result belongs to an older account session and was ignored."
        case let .switchBlocked(blocker):
            blocker.explanation
        case .accountNotReady:
            "The selected account is not ready yet."
        }
    }
}

/// Everything that may carry credentials or mutate durable state is owned by one account runtime.
/// Inactive runtimes remain alive so their pending sends/uploads can make bounded progress.
actor MessagingAccountRuntime {
    let accountId: String
    let deployment: String
    let paths: AccountStoragePaths
    let tokenStore: TokenStore
    let credentialCoordinator: SessionCredentialCoordinator
    let api: CloudAPI
    let localStore: CloudLocalStore
    let mediaEngine: CloudMediaTransferEngine

    private(set) var catalogGeneration: UInt64
    private(set) var callbackFence: UInt64 = 1
    private(set) var isForegroundOwner = false
    private(set) var requiresSignIn = false
    private var credentialTask: Task<Void, Never>?

    init(account: CatalogAccount, config: CloudConfig) throws {
        accountId = account.accountId
        deployment = account.deployment
        catalogGeneration = account.generation
        requiresSignIn = account.state == .signInAgain
        paths = try AccountStoragePaths.resolve(accountId: account.accountId)
        try paths.prepare()

        let databaseKeyStore = try LocalDatabaseKeyStore.accountScoped(accountId: account.accountId)
        let keyData = try databaseKeyStore.loadOrCreateKey()
        localStore = try CloudLocalStore(path: paths.database.path, key: keyData)
        tokenStore = TokenStore(service: "com.toj.cloud.account.\(account.accountId)")
        credentialCoordinator = SessionCredentialCoordinator()
        var scopedAPI = CloudAPI(config: config)
        scopedAPI.credentialCoordinator = credentialCoordinator
        api = scopedAPI
        let cache = try EncryptedMediaCache(root: paths.media, keyData: keyData)
        let defaults = UserDefaults(suiteName: "com.toj.media.account.\(account.accountId)") ?? .standard
        mediaEngine = CloudMediaTransferEngine(
            config: config,
            cache: cache,
            policyStore: MediaPolicyStore(defaults: defaults)
        )
    }

    deinit {
        credentialTask?.cancel()
    }

    func start(with account: CatalogAccount) async throws {
        guard account.accountId == accountId else { throw MessagingAccountRuntimeError.accountNotReady }
        catalogGeneration = account.generation
        callbackFence &+= 1
        try await tokenStore.save(account.storedSession)
        await credentialCoordinator.install(
            account.storedSession,
            config: api.config,
            tokenStore: tokenStore
        )
        requiresSignIn = account.state == .signInAgain
        try await mediaEngine.warmCache(localStore: localStore)
    }

    func beginCredentialEvents(
        onEvent: @escaping @Sendable (String, UInt64, SessionCredentialEvent) async -> Void
    ) {
        credentialTask?.cancel()
        let capturedFence = callbackFence
        let accountId = accountId
        let coordinator = credentialCoordinator
        credentialTask = Task {
            for await event in coordinator.updates {
                guard !Task.isCancelled else { return }
                await onEvent(accountId, capturedFence, event)
            }
        }
    }

    @discardableResult
    func claimForeground() -> UInt64 {
        callbackFence &+= 1
        isForegroundOwner = true
        return callbackFence
    }

    func releaseForeground() {
        callbackFence &+= 1
        isForegroundOwner = false
    }

    func updateCatalogGeneration(_ value: UInt64) {
        catalogGeneration = value
    }

    func acceptsCallback(fence: UInt64) -> Bool {
        fence == callbackFence && !requiresSignIn
    }

    func markAuthenticationRequired() async {
        callbackFence &+= 1
        requiresSignIn = true
        await credentialCoordinator.clear()
    }

    /// Irreversibly fences this runtime before foreground ownership can move to another account.
    /// This phase cannot fail; durable credential/file cleanup may be retried from the catalog
    /// tombstone if the later cleanup phase is interrupted.
    func fenceForRemoval() async {
        callbackFence &+= 1
        isForegroundOwner = false
        credentialTask?.cancel()
        credentialTask = nil
        await credentialCoordinator.clear()
    }

    /// Finishes fallible account-owned cleanup after the runtime has been fenced.
    func finishRemovalCleanup() async throws {
        try localStore.dbQueue.close()
        try await tokenStore.clearAllStoredData()
    }

    /// Stops this account permanently. Ordinary account switching does not call this method.
    func shutDownForRemoval() async throws {
        await fenceForRemoval()
        try await finishRemovalCleanup()
    }
}

/// Coordinates foreground ownership while preserving all account runtimes. UI-specific draft
/// flush/render/observer work is injected so switching is testable without SwiftUI.
actor MessagingAccountRuntimeRegistry {
    typealias SwitchBlocker = @Sendable () async -> AccountSwitchBlocker?
    typealias AccountAction = @Sendable (String) async throws -> Void

    private let catalog: AccountCatalog
    private let config: CloudConfig
    private var runtimes: [String: MessagingAccountRuntime] = [:]
    private var activeAccountId: String?
    private var roundRobinCursor = 0

    init(catalog: AccountCatalog, config: CloudConfig = .current) {
        self.catalog = catalog
        self.config = config
    }

    func restore() async throws -> AccountCatalogSnapshot {
        var snapshot = try await catalog.snapshot()
        for accountId in snapshot.pendingRemovalAccountIds {
            do {
                try await TokenStore(service: "com.toj.cloud.account.\(accountId)")
                    .clearAllStoredData()
                try AccountLocalStoreFactory.destroy(accountId: accountId)
                snapshot = try await catalog.finishRemoval(accountId: accountId)
            } catch {
                // Keep the durable tombstone and retry next launch. The removed credentials are
                // not reachable from the account list even when filesystem cleanup is delayed.
                continue
            }
        }
        for account in snapshot.accounts {
            let runtime = try runtime(for: account)
            try await runtime.start(with: account)
        }
        activeAccountId = snapshot.activeAccountId
        if let activeAccountId, let runtime = runtimes[activeAccountId] {
            _ = await runtime.claimForeground()
        }
        return snapshot
    }

    @discardableResult
    func switchAccount(
        to accountId: String,
        blocker: SwitchBlocker,
        saveDrafts: AccountAction,
        detachObservers: AccountAction,
        renderCachedState: AccountAction
    ) async throws -> MessagingAccountRuntime {
        if let reason = await blocker() {
            throw MessagingAccountRuntimeError.switchBlocked(reason)
        }
        let snapshot = try await catalog.snapshot()
        guard let target = snapshot.accounts.first(where: { $0.accountId == accountId }) else {
            throw AccountCatalogError.accountNotFound
        }
        if activeAccountId == accountId {
            return try runtime(for: target)
        }
        if let current = activeAccountId, let oldRuntime = runtimes[current] {
            try await saveDrafts(current)
            await oldRuntime.releaseForeground()
            try await detachObservers(current)
        }
        let activated = try await catalog.activate(accountId: accountId)
        let targetRuntime = try runtime(for: activated)
        await targetRuntime.updateCatalogGeneration(activated.generation)
        _ = await targetRuntime.claimForeground()
        activeAccountId = accountId
        // Paint SQLCipher state before any network request is allowed to start.
        try await renderCachedState(accountId)
        return targetRuntime
    }

    func runtime(accountId: String) -> MessagingAccountRuntime? {
        runtimes[accountId]
    }

    func aggregateUnreadCount() async throws -> Int {
        var total = 0
        for runtime in runtimes.values {
            total += try await runtime.localStore.aggregateUnreadCount()
        }
        return total
    }

    /// Runs at most one bounded unit per account, rotating the first account each pass. Callers put
    /// a push-routed account first without starving the remaining inactive accounts.
    func runRoundRobin(
        prioritizedAccountId: String? = nil,
        work: @escaping @Sendable (MessagingAccountRuntime) async -> Bool
    ) async {
        var ids = runtimes.keys.sorted()
        guard !ids.isEmpty else { return }
        let offset = roundRobinCursor % ids.count
        ids = Array(ids[offset...]) + Array(ids[..<offset])
        if let prioritizedAccountId,
           let index = ids.firstIndex(of: prioritizedAccountId) {
            ids.insert(ids.remove(at: index), at: 0)
        }
        for id in ids {
            guard let runtime = runtimes[id] else { continue }
            _ = await work(runtime)
        }
        roundRobinCursor = (roundRobinCursor + 1) % max(ids.count, 1)
    }

    func removeAccount(accountId: String) async throws -> AccountCatalogSnapshot {
        let removedForegroundAccount = activeAccountId == accountId
        var snapshot = try await catalog.beginRemoval(accountId: accountId)
        activeAccountId = snapshot.activeAccountId

        // Revoke the old runtime's callback/foreground ownership before handing ownership to its
        // replacement. Cleanup after this point is restart-safe through the durable tombstone.
        let removedRuntime = runtimes.removeValue(forKey: accountId)
        if let removedRuntime {
            await removedRuntime.fenceForRemoval()
        }
        if removedForegroundAccount,
           let activeAccountId,
           let activeRuntime = runtimes[activeAccountId] {
            _ = await activeRuntime.claimForeground()
        }
        if let removedRuntime {
            try await removedRuntime.finishRemovalCleanup()
        } else {
            try await TokenStore(service: "com.toj.cloud.account.\(accountId)")
                .clearAllStoredData()
        }
        try AccountLocalStoreFactory.destroy(accountId: accountId)
        snapshot = try await catalog.finishRemoval(accountId: accountId)
        activeAccountId = snapshot.activeAccountId
        return snapshot
    }

    private func runtime(for account: CatalogAccount) throws -> MessagingAccountRuntime {
        if let existing = runtimes[account.accountId] { return existing }
        guard account.deployment == AccountCatalog.normalizedDeployment(config.baseURL) else {
            throw AccountCatalogError.deploymentMismatch
        }
        let created = try MessagingAccountRuntime(account: account, config: config)
        runtimes[account.accountId] = created
        return created
    }

}
