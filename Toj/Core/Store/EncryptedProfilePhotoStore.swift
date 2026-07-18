import CryptoKit
import Foundation

/// Stores the local profile image as an encrypted, device-local app-container artifact. Profile
/// photos are intentionally separate from the cloud profile payload for now, but they receive the
/// same at-rest and backup protections as the local replica.
nonisolated enum EncryptedProfilePhotoStore {
    private static let formatHeader = Data([0x54, 0x4F, 0x4A, 0x50, 0x48, 0x01]) // TOJPH v1
    private static let keySalt = Data("com.toj.profile-photo.hkdf-salt.v1".utf8)
    private static let keyDomain = Data("com.toj.profile-photo.aes-gcm.v1".utf8)
    private static let authenticatedDataDomain = Data("com.toj.profile-photo.aad.v1".utf8)
    private static let operationState = OperationState()

    /// Re-enables profile-photo I/O after a real session has restored its encrypted replica. This
    /// is paired with `destroyAllSynchronously()`, which closes the gate before logout erasure so a
    /// late photo task cannot recreate the shared key or artifact.
    static func beginAuthenticatedSession() {
        operationState.lock.withLock {
            operationState.allowsOperations = true
        }
    }

    static func load(accountId: String) async -> Data? {
        await Task.detached(priority: .utility) {
            operationState.lock.withLock {
                guard operationState.allowsOperations else { return nil }
                return try? loadSynchronously(accountId: accountId)
            }
        }.value
    }

    static func persist(_ photoData: Data?, accountId: String) async -> Bool {
        await Task.detached(priority: .utility) {
            operationState.lock.withLock {
                guard operationState.allowsOperations else { return false }
                do {
                    try persistSynchronously(photoData, accountId: accountId)
                    return true
                } catch {
                    return false
                }
            }
        }.value
    }

    #if DEBUG
    static func loadForTesting(
        accountId: String,
        applicationSupportDirectory: URL,
        masterKey: Data
    ) async -> Data? {
        await Task.detached(priority: .utility) {
            operationState.lock.withLock {
                guard operationState.allowsOperations else { return nil }
                return try? loadSynchronously(
                    accountId: accountId,
                    supportRoot: applicationSupportDirectory,
                    masterKey: masterKey
                )
            }
        }.value
    }

    static func persistForTesting(
        _ photoData: Data?,
        accountId: String,
        applicationSupportDirectory: URL,
        masterKey: Data
    ) async -> Bool {
        await Task.detached(priority: .utility) {
            operationState.lock.withLock {
                guard operationState.allowsOperations else { return false }
                do {
                    try persistSynchronously(
                        photoData,
                        accountId: accountId,
                        supportRoot: applicationSupportDirectory,
                        masterKey: masterKey
                    )
                    return true
                } catch {
                    return false
                }
            }
        }.value
    }
    #endif

    /// Called after the local launch snapshot is published. It upgrades an older plaintext JPEG
    /// without delaying launch, and removes the plaintext only after the encrypted replacement has
    /// been written and authenticated successfully.
    @discardableResult
    static func migrateLegacySynchronously(accountId: String) -> Bool {
        operationState.lock.withLock {
            guard operationState.allowsOperations else { return false }
            do {
                _ = try loadSynchronously(accountId: accountId)
                return true
            } catch {
                return false
            }
        }
    }

    /// Closes the I/O gate and removes both the encrypted directory and every legacy plaintext
    /// profile image. The gate stays closed until the next authenticated session is ready.
    static func destroyAllSynchronously() throws {
        try operationState.lock.withLock {
            operationState.allowsOperations = false
            let support = try applicationSupportDirectory()
            let urls = [
                support
                    .appending(path: "Toj", directoryHint: .isDirectory)
                    .appending(path: "ProfilePhotos", directoryHint: .isDirectory),
                support.appending(path: "ProfilePhotos", directoryHint: .isDirectory),
            ]
            var firstError: Error?
            for url in urls where FileManager.default.fileExists(atPath: url.path) {
                do {
                    try FileManager.default.removeItem(at: url)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
        }
    }

    private static func loadSynchronously(
        accountId: String,
        supportRoot: URL? = nil,
        masterKey: Data? = nil
    ) throws -> Data? {
        guard !accountId.isEmpty else { return nil }
        let locations = try locations(accountId: accountId, supportRoot: supportRoot)
        let fileManager = FileManager.default
        let legacyExists = fileManager.fileExists(atPath: locations.legacy.path)

        if legacyExists {
            // If deletion is interrupted, the old artifact is at least protected from backup and
            // inaccessible until the first device unlock.
            try? applyFileSecurity(to: locations.legacy)
            try? applyBackupExclusion(to: locations.legacy.deletingLastPathComponent())
        }

        if fileManager.fileExists(atPath: locations.encrypted.path),
           let encrypted = try? Data(contentsOf: locations.encrypted, options: .mappedIfSafe),
           let photo = try? open(encrypted, accountId: accountId, masterKey: masterKey) {
            if legacyExists {
                try? fileManager.removeItem(at: locations.legacy)
            }
            return photo
        }

        guard legacyExists else { return nil }
        let legacyPhoto = try Data(contentsOf: locations.legacy, options: .mappedIfSafe)
        try writeEncrypted(
            legacyPhoto,
            accountId: accountId,
            masterKey: masterKey,
            to: locations.encrypted
        )

        // Authenticate a fresh read before destroying the only older copy.
        let written = try Data(contentsOf: locations.encrypted, options: .mappedIfSafe)
        guard try open(written, accountId: accountId, masterKey: masterKey) == legacyPhoto else {
            throw StoreError.verificationFailed
        }
        try fileManager.removeItem(at: locations.legacy)
        return legacyPhoto
    }

    private static func persistSynchronously(
        _ photoData: Data?,
        accountId: String,
        supportRoot: URL? = nil,
        masterKey: Data? = nil
    ) throws {
        guard !accountId.isEmpty else { throw StoreError.invalidAccount }
        let locations = try locations(accountId: accountId, supportRoot: supportRoot)
        let fileManager = FileManager.default

        guard let photoData else {
            var firstError: Error?
            for url in [locations.encrypted, locations.legacy]
                where fileManager.fileExists(atPath: url.path) {
                do {
                    try fileManager.removeItem(at: url)
                } catch {
                    if firstError == nil { firstError = error }
                }
            }
            if let firstError { throw firstError }
            return
        }

        try writeEncrypted(
            photoData,
            accountId: accountId,
            masterKey: masterKey,
            to: locations.encrypted
        )
        let written = try Data(contentsOf: locations.encrypted, options: .mappedIfSafe)
        guard try open(written, accountId: accountId, masterKey: masterKey) == photoData else {
            throw StoreError.verificationFailed
        }

        if fileManager.fileExists(atPath: locations.legacy.path) {
            try? applyFileSecurity(to: locations.legacy)
            try fileManager.removeItem(at: locations.legacy)
        }
    }

    private static func writeEncrypted(
        _ photoData: Data,
        accountId: String,
        masterKey: Data?,
        to url: URL
    ) throws {
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        try applyFileSecurity(to: directory)
        try applyBackupExclusion(to: directory)

        let key = try derivedKey(accountId: accountId, masterKey: masterKey)
        let sealed = try AES.GCM.seal(
            photoData,
            using: key,
            authenticating: authenticatedData(accountId: accountId)
        )
        guard let combined = sealed.combined else { throw StoreError.sealingFailed }
        var encoded = formatHeader
        encoded.append(combined)
        try encoded.write(
            to: url,
            options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication]
        )
        try applyFileSecurity(to: url)
        try applyBackupExclusion(to: url)
    }

    private static func open(_ encoded: Data, accountId: String, masterKey: Data?) throws -> Data {
        guard encoded.starts(with: formatHeader), encoded.count > formatHeader.count else {
            throw StoreError.invalidFormat
        }
        let box = try AES.GCM.SealedBox(combined: Data(encoded.dropFirst(formatHeader.count)))
        return try AES.GCM.open(
            box,
            using: derivedKey(accountId: accountId, masterKey: masterKey),
            authenticating: authenticatedData(accountId: accountId)
        )
    }

    private static func derivedKey(accountId: String, masterKey: Data?) throws -> SymmetricKey {
        let masterKey = try masterKey ?? LocalDatabaseKeyStore.currentEnvironment().loadOrCreateKey()
        var info = keyDomain
        info.append(0)
        info.append(contentsOf: SHA256.hash(data: Data(accountId.utf8)))
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: masterKey),
            salt: keySalt,
            info: info,
            outputByteCount: 32
        )
    }

    private static func authenticatedData(accountId: String) -> Data {
        var data = authenticatedDataDomain
        data.append(0)
        data.append(Data(accountId.utf8))
        return data
    }

    private static func locations(
        accountId: String,
        supportRoot: URL? = nil
    ) throws -> (encrypted: URL, legacy: URL) {
        let support = try supportRoot ?? applicationSupportDirectory()
        let digest = SHA256.hash(data: Data(accountId.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        let encrypted = support
            .appending(path: "Toj", directoryHint: .isDirectory)
            .appending(path: "ProfilePhotos", directoryHint: .isDirectory)
            .appending(path: "\(fileName).tojprofile")
        let safeLegacyAccountId = String(accountId.map { character in
            character.isLetter || character.isNumber || character == "-" ? character : "_"
        })
        let legacy = support
            .appending(path: "ProfilePhotos", directoryHint: .isDirectory)
            .appending(path: "\(safeLegacyAccountId).jpg")
        return (encrypted, legacy)
    }

    private static func applicationSupportDirectory() throws -> URL {
        try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
    }

    private static func applyFileSecurity(to url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
    }

    private static func applyBackupExclusion(to url: URL) throws {
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var securedURL = url
        try securedURL.setResourceValues(values)
    }

    private enum StoreError: Error {
        case invalidAccount
        case invalidFormat
        case sealingFailed
        case verificationFailed
    }

    private final class OperationState: @unchecked Sendable {
        let lock = NSLock()
        var allowsOperations = true
    }
}
