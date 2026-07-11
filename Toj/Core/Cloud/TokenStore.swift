import Foundation
import Security

actor TokenStore {
    private let service = "com.toj.cloud"
    private let sessionAccount = "device-session"
    private let pendingRevocationAccount = "pending-session-revocation"
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    func load() throws -> StoredCloudSession? {
        guard let data = try loadData(account: sessionAccount) else { return nil }
        return try decoder.decode(StoredCloudSession.self, from: data)
    }

    func save(_ session: StoredCloudSession) throws {
        try saveData(encoder.encode(session), account: sessionAccount)
    }

    func clear() throws {
        try clearData(account: sessionAccount)
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

struct KeychainError: Error, LocalizedError {
    let status: OSStatus

    var errorDescription: String? {
        SecCopyErrorMessageString(status, nil) as String? ?? "Keychain error \(status)"
    }
}
