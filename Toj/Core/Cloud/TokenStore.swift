import Foundation
import LocalAuthentication
import Observation
import Security

actor TokenStore {
    private let service: String
    private let sessionAccount = "device-session"
    private let pendingRevocationAccount = "pending-session-revocation"
    private let pendingLocalErasureAccount = "pending-local-erasure"
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

    func loadPendingRevocationToken() throws -> String? {
        guard let data = try loadData(account: pendingRevocationAccount) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    func savePendingRevocationToken(_ token: String) throws {
        try saveData(Data(token.utf8), account: pendingRevocationAccount)
    }

    func clearPendingRevocationToken() throws {
        try clearData(account: pendingRevocationAccount)
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
           Date().timeIntervalSince(leftForegroundAt) >= TimeInterval(policy.timeout.rawValue) {
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
