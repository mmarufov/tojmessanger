import Foundation
import LocalAuthentication
import Observation
import Security

nonisolated struct PendingSessionRevocation: Codable, Equatable, Sendable {
    let token: String
    var eraseLocalReplicaOnLaunch: Bool
    var localReplicaAccountId: String?
}

nonisolated enum PendingRevocationLaunchAction: Equatable, Sendable {
    case restoreSavedSession
    case requireAuthentication(localReplicaAccountId: String?)
    case eraseLocalReplica
}

nonisolated enum PendingRevocationLaunchPolicy {
    static func action(
        savedSession: StoredCloudSession?,
        pendingRevocations: [PendingSessionRevocation],
        hasPendingLocalErasure: Bool,
        pendingReauthenticationAccountId: String? = nil
    ) -> PendingRevocationLaunchAction {
        if hasPendingLocalErasure { return .eraseLocalReplica }

        if let savedSession {
            // A credential rotation can persist its replacement immediately before an explicit
            // logout wins. Match the account as well as the superseded token so that crash window
            // cannot resurrect a session the user asked Toj to remove.
            if pendingRevocations.contains(where: {
                $0.eraseLocalReplicaOnLaunch
                    && ($0.token == savedSession.session.token
                        || $0.localReplicaAccountId == savedSession.session.accountId)
            }) {
                return .eraseLocalReplica
            }
            if let pendingReauthenticationAccountId {
                return .requireAuthentication(
                    localReplicaAccountId: pendingReauthenticationAccountId
                )
            }
            if pendingRevocations.contains(where: {
                !$0.eraseLocalReplicaOnLaunch
                    && ($0.token == savedSession.session.token
                        || $0.localReplicaAccountId == savedSession.session.accountId)
            }) {
                return .requireAuthentication(
                    localReplicaAccountId: savedSession.session.accountId
                )
            }
            return .restoreSavedSession
        }

        if pendingRevocations.contains(where: \.eraseLocalReplicaOnLaunch) {
            // This is also the conservative behavior for markers written by older builds, which
            // carried no account metadata and only represented interrupted explicit sign-out.
            return .eraseLocalReplica
        }
        if let pendingReauthenticationAccountId {
            return .requireAuthentication(
                localReplicaAccountId: pendingReauthenticationAccountId
            )
        }
        if let pending = pendingRevocations.first(where: { $0.localReplicaAccountId != nil }) {
            return .requireAuthentication(localReplicaAccountId: pending.localReplicaAccountId)
        }
        return .restoreSavedSession
    }
}

actor TokenStore {
    private let service: String
    private let sessionAccount = "device-session"
    private let pendingRevocationAccount = "pending-session-revocation"
    private let pendingLocalErasureAccount = "pending-local-erasure"
    private let pendingReauthenticationAccount = "pending-reauthentication"
    private let pendingRefreshRotationAccount = "pending-refresh-rotation"
    private let profileAccountPrefix = "profile-"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    init(service: String? = nil) {
        #if DEBUG
        let fixtureService = ProcessInfo.processInfo.environment["TOJ_UI_FIXTURE"] == "telegram-fast"
            ? "com.toj.cloud.ui-fixture"
            : nil
        #else
        let fixtureService: String? = nil
        #endif
        self.service = service ?? fixtureService ?? "com.toj.cloud"
    }

    func load() throws -> StoredCloudSession? {
        guard let data = try loadData(account: sessionAccount) else { return nil }
        return try decoder.decode(StoredCloudSession.self, from: data)
    }

    func save(_ session: StoredCloudSession) throws {
        try saveData(encoder.encode(session), account: sessionAccount)
    }

    func clear() throws {
        try clearData(account: sessionAccount)
        try clearData(account: pendingRefreshRotationAccount)
    }

    /// Permanently removes every item owned by this account-scoped service. This is deliberately
    /// broader than `clear()`, which preserves crash markers used by the legacy singleton flow.
    func clearAllStoredData() throws {
        let status = SecItemDelete([
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ] as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError(status: status)
        }
    }

    /// Removes a stale refresh result without risking a newer account/session written meanwhile.
    func clearSession(ifTokenMatches token: String) throws {
        guard let current = try load(), current.session.token == token else { return }
        try clear()
    }

    func loadProfile(accountId: String) throws -> StoredProfileDetails? {
        guard let data = try loadData(account: profileAccountPrefix + accountId) else { return nil }
        return try decoder.decode(StoredProfileDetails.self, from: data)
    }

    func saveProfile(_ profile: StoredProfileDetails, accountId: String) throws {
        try saveData(encoder.encode(profile), account: profileAccountPrefix + accountId)
    }

    func clearProfile(accountId: String) throws {
        try clearData(account: profileAccountPrefix + accountId)
    }

    func loadPendingRevocations() throws -> [PendingSessionRevocation] {
        guard let data = try loadData(account: pendingRevocationAccount) else { return [] }
        if let queued = try? decoder.decode([PendingSessionRevocation].self, from: data) {
            return Self.normalizedPendingRevocations(queued)
        }
        if let queued = try? decoder.decode([String].self, from: data) {
            return Self.normalizedPendingRevocations(queued.map {
                PendingSessionRevocation(
                    token: $0,
                    eraseLocalReplicaOnLaunch: true,
                    localReplicaAccountId: nil
                )
            })
        }
        // Pre-queue builds stored one raw UTF-8 token. Read it indefinitely so an update cannot
        // lose the only credential capable of cleaning up an abandoned server session.
        guard let legacy = String(data: data, encoding: .utf8), !legacy.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return [PendingSessionRevocation(
            token: legacy,
            eraseLocalReplicaOnLaunch: true,
            localReplicaAccountId: nil
        )]
    }

    func loadPendingRevocationTokens() throws -> [String] {
        try loadPendingRevocations().map(\.token)
    }

    func loadPendingRevocationToken() throws -> String? {
        try loadPendingRevocationTokens().first
    }

    func savePendingRevocationToken(
        _ token: String,
        eraseLocalReplicaOnLaunch: Bool = true,
        localReplicaAccountId: String? = nil
    ) throws {
        guard !token.isEmpty else { return }
        var queued = try loadPendingRevocations()
        if let index = queued.firstIndex(where: { $0.token == token }) {
            let wasErasing = queued[index].eraseLocalReplicaOnLaunch
            queued[index].eraseLocalReplicaOnLaunch = wasErasing || eraseLocalReplicaOnLaunch
            if queued[index].localReplicaAccountId == nil
                || (!wasErasing && eraseLocalReplicaOnLaunch) {
                queued[index].localReplicaAccountId = localReplicaAccountId
            }
        } else {
            queued.append(PendingSessionRevocation(
                token: token,
                eraseLocalReplicaOnLaunch: eraseLocalReplicaOnLaunch,
                localReplicaAccountId: localReplicaAccountId
            ))
        }
        try saveData(encoder.encode(queued), account: pendingRevocationAccount)
    }

    func clearPendingRevocationToken() throws {
        try clearData(account: pendingRevocationAccount)
    }

    /// Clears only the revocation intent owned by this exact credential. A late successful revoke
    /// must never erase a newer or different account's crash-recovery marker.
    func clearPendingRevocationToken(ifMatches token: String) throws {
        var queued = try loadPendingRevocations()
        guard queued.contains(where: { $0.token == token }) else { return }
        queued.removeAll(where: { $0.token == token })
        if queued.isEmpty {
            try clearPendingRevocationToken()
        } else {
            try saveData(encoder.encode(queued), account: pendingRevocationAccount)
        }
    }

    /// Keeps an unreachable server credential queued without letting it fence or erase the local
    /// replica. This exact-token transition is used when a staged different-account login is
    /// canceled; changing every marker for that account could weaken an unrelated security reissue.
    func markPendingRevocationRemoteOnly(ifMatches token: String) throws {
        var queued = try loadPendingRevocations()
        guard let index = queued.firstIndex(where: { $0.token == token }) else { return }
        guard !queued[index].eraseLocalReplicaOnLaunch,
              queued[index].localReplicaAccountId != nil
        else { return }
        queued[index].localReplicaAccountId = nil
        try saveData(encoder.encode(queued), account: pendingRevocationAccount)
    }

    /// Once the destructive replica cleanup commits, queued tokens remain useful for remote
    /// revocation but must no longer erase a future login if the network cleanup is still retrying.
    func markPendingRevocationLocalErasureCompleted(accountId: String?) throws {
        var queued = try loadPendingRevocations()
        var changed = false
        for index in queued.indices {
            let representedErasedReplica = accountId != nil
                && queued[index].localReplicaAccountId == accountId
            guard queued[index].eraseLocalReplicaOnLaunch || representedErasedReplica else {
                continue
            }
            if queued[index].eraseLocalReplicaOnLaunch
                || queued[index].localReplicaAccountId != nil {
                queued[index].eraseLocalReplicaOnLaunch = false
                queued[index].localReplicaAccountId = nil
                changed = true
            }
        }
        guard changed else { return }
        try saveData(encoder.encode(queued), account: pendingRevocationAccount)
    }

    /// A successful login for the preserved replica resolves only its local ambiguity. Abandoned
    /// tokens still stay queued for best-effort server revocation.
    func markPendingRevocationsRemoteOnly(localReplicaAccountId accountId: String) throws {
        var queued = try loadPendingRevocations()
        var changed = false
        for index in queued.indices
        where !queued[index].eraseLocalReplicaOnLaunch
            && queued[index].localReplicaAccountId == accountId {
            queued[index].localReplicaAccountId = nil
            changed = true
        }
        guard changed else { return }
        try saveData(encoder.encode(queued), account: pendingRevocationAccount)
    }

    private static func normalizedPendingRevocations(
        _ queued: [PendingSessionRevocation]
    ) -> [PendingSessionRevocation] {
        queued.reduce(into: []) { result, pending in
            guard !pending.token.isEmpty else { return }
            guard let index = result.firstIndex(where: { $0.token == pending.token }) else {
                result.append(pending)
                return
            }
            let wasErasing = result[index].eraseLocalReplicaOnLaunch
            result[index].eraseLocalReplicaOnLaunch = wasErasing
                || pending.eraseLocalReplicaOnLaunch
            if result[index].localReplicaAccountId == nil
                || (!wasErasing && pending.eraseLocalReplicaOnLaunch) {
                result[index].localReplicaAccountId = pending.localReplicaAccountId
            }
        }
    }

    /// Crash-safe marker written before explicit logout starts deleting local state. Its payload
    /// keeps the account id available even if the active session item was already removed.
    func savePendingLocalErasure(accountId: String?) throws {
        try saveData(Data((accountId ?? "").utf8), account: pendingLocalErasureAccount)
    }

    func hasPendingLocalErasure() throws -> Bool {
        try loadData(account: pendingLocalErasureAccount) != nil
    }

    func clearPendingLocalErasure() throws {
        try clearData(account: pendingLocalErasureAccount)
    }

    /// Persists the account identity of an encrypted replica whose remote session expired. The
    /// session credential itself can then be removed without letting a relaunch forget that the
    /// preserved replica must be reauthenticated or explicitly erased before account replacement.
    func savePendingReauthentication(accountId: String) throws {
        guard !accountId.isEmpty else { throw CocoaError(.fileWriteInvalidFileName) }
        try saveData(Data(accountId.utf8), account: pendingReauthenticationAccount)
    }

    func loadPendingReauthenticationAccountId() throws -> String? {
        guard let data = try loadData(account: pendingReauthenticationAccount) else { return nil }
        guard let accountId = String(data: data, encoding: .utf8), !accountId.isEmpty else {
            throw CocoaError(.fileReadCorruptFile)
        }
        return accountId
    }

    func clearPendingReauthentication() throws {
        try clearData(account: pendingReauthenticationAccount)
    }

    func loadPendingRefreshRotation() throws -> String? {
        guard let data = try loadData(account: pendingRefreshRotationAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func savePendingRefreshRotation(_ rotationId: String) throws {
        try saveData(Data(rotationId.utf8), account: pendingRefreshRotationAccount)
    }

    func clearPendingRefreshRotation() throws {
        try clearData(account: pendingRefreshRotationAccount)
    }

    /// Explicit logout removes every locally cached profile. Enumerating this app's Keychain
    /// service also covers an interrupted logout whose active session item is already gone.
    func clearAllProfiles() throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecReturnAttributes as String: true,
            kSecMatchLimit as String: kSecMatchLimitAll,
        ]
        var items: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &items)
        if status == errSecItemNotFound { return }
        guard status == errSecSuccess else { throw KeychainError(status: status) }

        let attributes: [[String: Any]]
        if let many = items as? [[String: Any]] {
            attributes = many
        } else if let one = items as? [String: Any] {
            attributes = [one]
        } else {
            throw KeychainError(status: errSecDecode)
        }
        for item in attributes {
            guard
                let account = item[kSecAttrAccount as String] as? String,
                account.hasPrefix(profileAccountPrefix)
            else { continue }
            try clearData(account: account)
        }
    }

    private func loadData(account: String) throws -> Data? {
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

    private func saveData(_ data: Data, account: String) throws {
        var query = baseQuery(account: account)
        let attributes = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw KeychainError(status: status) }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainError(status: addStatus)
        }
    }

    private func clearData(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        if status == errSecSuccess || status == errSecItemNotFound { return }
        throw KeychainError(status: status)
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

nonisolated struct StoredProfileDetails: Codable, Equatable, Sendable {
    var username: String? = nil
    var firstName: String
    var lastName: String
    var bio: String
    var birthday: Date?
    var colorIndex: Int
    var serverUpdatedAt: String? = nil
    var pendingSync: Bool? = nil

    static let empty = StoredProfileDetails(
        username: nil,
        firstName: "",
        lastName: "",
        bio: "",
        birthday: nil,
        colorIndex: 0
    )

    var displayName: String {
        [firstName, lastName]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    var needsServerSync: Bool { pendingSync ?? false }
}

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}

nonisolated enum AppLockTimeout: Int, Codable, CaseIterable, Identifiable, Sendable {
    case immediate = 0
    case oneMinute = 60
    case fiveMinutes = 300
    case oneHour = 3_600

    var id: Int { rawValue }

    var title: String {
        switch self {
        case .immediate: "Immediately"
        case .oneMinute: "After 1 minute"
        case .fiveMinutes: "After 5 minutes"
        case .oneHour: "After 1 hour"
        }
    }

    func shouldLock(after elapsed: TimeInterval) -> Bool {
        elapsed >= TimeInterval(rawValue)
    }
}

private struct AppLockPolicy: Codable {
    var enabled = false
    var timeout: AppLockTimeout = .oneMinute
}

private struct AppLockPolicyStore {
    private let service = "com.toj.app-lock"
    private let account = "policy-v1"

    func load() throws -> AppLockPolicy {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        if status == errSecItemNotFound { return AppLockPolicy() }
        guard status == errSecSuccess, let data = item as? Data else {
            throw KeychainError(status: status)
        }
        return try JSONDecoder().decode(AppLockPolicy.self, from: data)
    }

    func save(_ policy: AppLockPolicy) throws {
        let data = try JSONEncoder().encode(policy)
        let status = SecItemUpdate(
            baseQuery as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )
        if status == errSecSuccess { return }
        if status != errSecItemNotFound { throw KeychainError(status: status) }
        var query = baseQuery
        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else { throw KeychainError(status: addStatus) }
    }

    private var baseQuery: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}

@MainActor
@Observable
final class AppLockController {
    static let shared = AppLockController()

    private let store = AppLockPolicyStore()
    private var policy: AppLockPolicy
    private var leftForegroundAt: Date?

    private(set) var isLocked: Bool
    private(set) var privacyShieldVisible = false
    private(set) var authenticationInFlight = false
    private(set) var errorMessage: String?

    var isEnabled: Bool { policy.enabled }
    var timeout: AppLockTimeout { policy.timeout }
    var presentsGate: Bool { policy.enabled && (isLocked || privacyShieldVisible) }

    private init() {
        let loaded = (try? store.load()) ?? AppLockPolicy()
        policy = loaded
        isLocked = loaded.enabled
    }

    func becameInactive() {
        guard policy.enabled else { return }
        privacyShieldVisible = true
        if leftForegroundAt == nil { leftForegroundAt = Date() }
        if policy.timeout == .immediate { isLocked = true }
    }

    func becameActive() {
        guard policy.enabled else {
            privacyShieldVisible = false
            leftForegroundAt = nil
            return
        }
        if let leftForegroundAt,
           policy.timeout.shouldLock(after: Date().timeIntervalSince(leftForegroundAt)) {
            isLocked = true
        }
        self.leftForegroundAt = nil
        if !isLocked { privacyShieldVisible = false }
    }

    func unlock() async {
        guard policy.enabled, !authenticationInFlight else { return }
        if await authenticate(reason: "Unlock Toj") {
            isLocked = false
            privacyShieldVisible = false
            errorMessage = nil
        }
    }

    func setEnabled(_ enabled: Bool) async -> Bool {
        guard enabled != policy.enabled else { return true }
        guard await authenticate(reason: enabled ? "Turn on App Lock" : "Turn off App Lock") else {
            if policy.enabled { isLocked = true }
            return false
        }
        policy.enabled = enabled
        do {
            try store.save(policy)
            isLocked = false
            privacyShieldVisible = false
            errorMessage = nil
            return true
        } catch {
            policy.enabled.toggle()
            errorMessage = error.localizedDescription
            return false
        }
    }

    func setTimeout(_ timeout: AppLockTimeout) async -> Bool {
        guard timeout != policy.timeout else { return true }
        guard await authenticate(reason: "Change the App Lock timeout") else {
            if policy.enabled { isLocked = true }
            return false
        }
        let previous = policy.timeout
        policy.timeout = timeout
        do {
            try store.save(policy)
            errorMessage = nil
            return true
        } catch {
            policy.timeout = previous
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func authenticate(reason: String) async -> Bool {
        authenticationInFlight = true
        defer { authenticationInFlight = false }
        let context = LAContext()
        var authorizationError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &authorizationError) else {
            errorMessage = authorizationError?.localizedDescription
                ?? "Set a device passcode before enabling App Lock."
            return false
        }
        do {
            let accepted = try await context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: reason
            )
            if !accepted { errorMessage = "Authentication was not completed." }
            return accepted
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
