import Foundation
import Security

nonisolated enum CatalogSessionState: String, Codable, Equatable, Sendable {
    case authenticated
    case signInAgain = "sign_in_again"
}

nonisolated struct CatalogAccount: Codable, Equatable, Identifiable, Sendable {
    let accountId: String
    let deployment: String
    var storedSession: StoredCloudSession
    var state: CatalogSessionState
    var generation: UInt64
    var addedAt: Date
    var lastActivatedAt: Date

    var id: String { accountId }
}

nonisolated struct AccountCatalogSnapshot: Codable, Equatable, Sendable {
    var version = 1
    var activeAccountId: String?
    var revision: UInt64 = 0
    var accounts: [CatalogAccount] = []

    static let empty = AccountCatalogSnapshot()
}

nonisolated enum AccountCatalogError: LocalizedError, Equatable, Sendable {
    case accountLimitReached
    case duplicateAccount(existingDeviceId: String)
    case accountNotFound
    case deploymentMismatch
    case staleGeneration
    case invalidAccountIdentifier

    var errorDescription: String? {
        switch self {
        case .accountLimitReached:
            "You can use up to three Toj accounts on this device."
        case .duplicateAccount:
            "This account is already added. The redundant login must be revoked."
        case .accountNotFound:
            "That account is no longer stored on this device."
        case .deploymentMismatch:
            "All accounts must use the same Toj deployment."
        case .staleGeneration:
            "The account changed while this operation was finishing."
        case .invalidAccountIdentifier:
            "The server returned an invalid account identifier."
        }
    }
}

/// The only process-wide account index. Credentials themselves are consumed by account-owned
/// runtimes and coordinators; there is deliberately no process-wide active credential singleton.
actor AccountCatalog {
    static let maximumAccounts = 3

    private let keychain: AccountCatalogKeychain
    private var cached: AccountCatalogSnapshot?

    init(service: String = "com.toj.account-catalog") {
        keychain = AccountCatalogKeychain(service: service)
    }

    func snapshot() throws -> AccountCatalogSnapshot {
        if let cached { return cached }
        let loaded = try keychain.loadCatalog() ?? .empty
        try Self.validate(loaded)
        cached = loaded
        return loaded
    }

    func installationId() throws -> String {
        if let existing = try keychain.loadInstallationId() { return existing }
        let created = UUID().uuidString.lowercased()
        try keychain.saveInstallationId(created)
        return created
    }

    /// Adds a newly authenticated session. A duplicate is intentionally not absorbed: the caller
    /// must revoke the newly created redundant server device session before returning to the user.
    @discardableResult
    func add(
        _ storedSession: StoredCloudSession,
        deployment: URL,
        now: Date = Date()
    ) throws -> CatalogAccount {
        var value = try snapshot()
        let accountId = storedSession.session.accountId.lowercased()
        guard Self.isValidAccountId(accountId) else { throw AccountCatalogError.invalidAccountIdentifier }
        if let existing = value.accounts.first(where: { $0.accountId == accountId }) {
            throw AccountCatalogError.duplicateAccount(existingDeviceId: existing.storedSession.session.deviceId)
        }
        guard value.accounts.count < Self.maximumAccounts else {
            throw AccountCatalogError.accountLimitReached
        }
        let normalizedDeployment = Self.normalizedDeployment(deployment)
        if let first = value.accounts.first, first.deployment != normalizedDeployment {
            throw AccountCatalogError.deploymentMismatch
        }
        let account = CatalogAccount(
            accountId: accountId,
            deployment: normalizedDeployment,
            storedSession: storedSession,
            state: .authenticated,
            generation: 1,
            addedAt: now,
            lastActivatedAt: now
        )
        value.accounts.append(account)
        value.activeAccountId = accountId
        value.revision &+= 1
        try persist(value)
        return account
    }

    @discardableResult
    func activate(accountId: String, now: Date = Date()) throws -> CatalogAccount {
        var value = try snapshot()
        guard let index = value.accounts.firstIndex(where: { $0.accountId == accountId }) else {
            throw AccountCatalogError.accountNotFound
        }
        if let oldIndex = value.activeAccountId.flatMap({ active in
            value.accounts.firstIndex(where: { $0.accountId == active })
        }), oldIndex != index {
            // Fence callbacks captured by the account that just stopped owning the foreground UI.
            value.accounts[oldIndex].generation &+= 1
        }
        value.accounts[index].generation &+= 1
        value.accounts[index].lastActivatedAt = now
        value.activeAccountId = accountId
        value.revision &+= 1
        try persist(value)
        return value.accounts[index]
    }

    @discardableResult
    func replaceSession(
        accountId: String,
        expectedGeneration: UInt64,
        with storedSession: StoredCloudSession
    ) throws -> CatalogAccount {
        var value = try snapshot()
        guard let index = value.accounts.firstIndex(where: { $0.accountId == accountId }) else {
            throw AccountCatalogError.accountNotFound
        }
        guard value.accounts[index].generation == expectedGeneration else {
            throw AccountCatalogError.staleGeneration
        }
        guard storedSession.session.accountId.lowercased() == accountId else {
            throw AccountCatalogError.invalidAccountIdentifier
        }
        value.accounts[index].storedSession = storedSession
        value.accounts[index].state = .authenticated
        value.revision &+= 1
        try persist(value)
        return value.accounts[index]
    }

    @discardableResult
    func markSignInAgain(accountId: String) throws -> CatalogAccount {
        var value = try snapshot()
        guard let index = value.accounts.firstIndex(where: { $0.accountId == accountId }) else {
            throw AccountCatalogError.accountNotFound
        }
        value.accounts[index].generation &+= 1
        value.accounts[index].state = .signInAgain
        value.revision &+= 1
        try persist(value)
        return value.accounts[index]
    }

    @discardableResult
    func remove(accountId: String) throws -> AccountCatalogSnapshot {
        var value = try snapshot()
        guard let removedIndex = value.accounts.firstIndex(where: { $0.accountId == accountId }) else {
            throw AccountCatalogError.accountNotFound
        }
        value.accounts.remove(at: removedIndex)
        if value.activeAccountId == accountId {
            value.activeAccountId = value.accounts
                .max(by: { $0.lastActivatedAt < $1.lastActivatedAt })?
                .accountId
        }
        value.revision &+= 1
        try persist(value)
        return value
    }

    /// Used only after the account-scoped database/media copy has opened and passed integrity.
    func installMigratedLegacyAccount(
        _ storedSession: StoredCloudSession,
        deployment: URL,
        now: Date = Date()
    ) throws -> CatalogAccount {
        var value = try snapshot()
        if let existing = value.accounts.first(where: {
            $0.accountId == storedSession.session.accountId.lowercased()
        }) { return existing }
        return try add(storedSession, deployment: deployment, now: now)
    }

    private func persist(_ value: AccountCatalogSnapshot) throws {
        try Self.validate(value)
        try keychain.saveCatalog(value)
        cached = value
    }

    private static func validate(_ value: AccountCatalogSnapshot) throws {
        guard value.accounts.count <= maximumAccounts else { throw AccountCatalogError.accountLimitReached }
        guard Set(value.accounts.map(\.accountId)).count == value.accounts.count,
              value.accounts.allSatisfy({ isValidAccountId($0.accountId) })
        else { throw AccountCatalogError.invalidAccountIdentifier }
        if let active = value.activeAccountId,
           !value.accounts.contains(where: { $0.accountId == active }) {
            throw AccountCatalogError.accountNotFound
        }
        if let deployment = value.accounts.first?.deployment,
           value.accounts.contains(where: { $0.deployment != deployment }) {
            throw AccountCatalogError.deploymentMismatch
        }
    }

    nonisolated private static func normalizedDeployment(_ url: URL) -> String {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.query = nil
        components?.fragment = nil
        var value = components?.url?.absoluteString ?? url.absoluteString
        while value.last == "/" { value.removeLast() }
        return value.lowercased()
    }

    nonisolated static func isValidAccountId(_ value: String) -> Bool {
        UUID(uuidString: value) != nil && !value.contains("/") && !value.contains("..")
    }
}

private struct AccountCatalogKeychain: Sendable {
    private let service: String
    private let catalogAccount = "catalog-v1"
    private let installationAccount = "installation-id-v1"

    init(service: String) {
        self.service = service
    }

    func loadCatalog() throws -> AccountCatalogSnapshot? {
        guard let data = try load(account: catalogAccount) else { return nil }
        return try JSONDecoder().decode(AccountCatalogSnapshot.self, from: data)
    }

    func saveCatalog(_ value: AccountCatalogSnapshot) throws {
        try save(JSONEncoder().encode(value), account: catalogAccount)
    }

    func loadInstallationId() throws -> String? {
        guard let data = try load(account: installationAccount),
              let value = String(data: data, encoding: .utf8),
              UUID(uuidString: value) != nil
        else { return nil }
        return value.lowercased()
    }

    func saveInstallationId(_ value: String) throws {
        try save(Data(value.utf8), account: installationAccount)
    }

    private func load(account: String) throws -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return data
    }

    private func save(_ data: Data, account: String) throws {
        let query = baseQuery(account: account)
        let status = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw KeychainError(status: status) }
        var insert = query
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
