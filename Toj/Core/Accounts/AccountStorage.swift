import Foundation

nonisolated struct AccountStoragePaths: Equatable, Sendable {
    let accountId: String
    let root: URL
    let database: URL
    let media: URL
    let backgroundMediaJobs: URL

    static func resolve(accountId: String, fileManager: FileManager = .default) throws -> Self {
        let normalized = accountId.lowercased()
        guard AccountCatalog.isValidAccountId(normalized) else {
            throw AccountCatalogError.invalidAccountIdentifier
        }
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let productDirectory = support.appending(
            path: LocalDatabaseKeyStore.usesTelegramFastUITestFixture ? "TojUITest" : "Toj",
            directoryHint: .isDirectory
        )
        let root = productDirectory
            .appending(path: "Accounts", directoryHint: .isDirectory)
            .appending(path: normalized, directoryHint: .isDirectory)
        return Self(
            accountId: normalized,
            root: root,
            database: root.appending(path: "cloud.sqlite"),
            media: root.appending(path: "media", directoryHint: .isDirectory),
            backgroundMediaJobs: root.appending(path: "background-media-jobs.json")
        )
    }

    func prepare(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(
            at: root,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try fileManager.createDirectory(
            at: media,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        try Self.protect(root)
        try Self.protect(media)
    }

    private static func protect(_ url: URL) throws {
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
            ofItemAtPath: url.path
        )
        var mutable = url
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try mutable.setResourceValues(values)
    }
}

nonisolated enum AccountLocalStoreFactory {
    static func open(accountId: String) throws -> CloudLocalStore {
        let paths = try AccountStoragePaths.resolve(accountId: accountId)
        try paths.prepare()
        let key = try LocalDatabaseKeyStore.accountScoped(accountId: accountId).loadOrCreateKey()
        return try CloudLocalStore(path: paths.database.path, key: key)
    }

    /// Removes one selected account only. The account runtime must release its DatabasePool first.
    static func destroy(accountId: String, fileManager: FileManager = .default) throws {
        let paths = try AccountStoragePaths.resolve(accountId: accountId, fileManager: fileManager)
        var firstError: Error?
        if fileManager.fileExists(atPath: paths.root.path) {
            do { try fileManager.removeItem(at: paths.root) }
            catch { firstError = error }
        }
        do { try LocalDatabaseKeyStore.accountScoped(accountId: accountId).deleteKey() }
        catch { if firstError == nil { firstError = error } }
        if let firstError { throw firstError }
    }
}

nonisolated struct LegacyAccountStorageMigrationResult: Equatable, Sendable {
    let paths: AccountStoragePaths
    let copiedLegacyDatabase: Bool
    let copiedLegacyMedia: Bool
}

/// Crash-safe, idempotent migration from the original singleton paths. The legacy replica and key
/// are never deleted by this expand-phase migrator, so an older build remains rollback-readable.
actor LegacyAccountStorageMigrator {
    private struct Marker: Codable, Equatable {
        var version: Int
        var accountId: String
        var databaseIntegrityVerified: Bool
        var mediaCopied: Bool
        var completedAt: Date
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func migrateIfNeeded(accountId: String) throws -> LegacyAccountStorageMigrationResult {
        let normalized = accountId.lowercased()
        let finalPaths = try AccountStoragePaths.resolve(accountId: normalized, fileManager: fileManager)
        let markerURL = finalPaths.root.appending(path: "legacy-migration-v1.json")
        if let marker = try loadMarker(at: markerURL),
           marker.version == 1,
           marker.accountId == normalized,
           marker.databaseIntegrityVerified {
            _ = try AccountLocalStoreFactory.open(accountId: normalized)
            return LegacyAccountStorageMigrationResult(
                paths: finalPaths,
                copiedLegacyDatabase: true,
                copiedLegacyMedia: marker.mediaCopied
            )
        }

        let legacyRoot = try legacyApplicationDirectory()
        let legacyDatabase = legacyRoot.appending(path: "cloud.sqlite")
        let accountsRoot = finalPaths.root.deletingLastPathComponent()
        try fileManager.createDirectory(
            at: accountsRoot,
            withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )

        // A crash can occur after the verified directory rename but before the caller updates the
        // catalog. Re-open that exact copy and finish the marker instead of recopying over it.
        if fileManager.fileExists(atPath: finalPaths.database.path) {
            let key = try LocalDatabaseKeyStore.accountScoped(accountId: normalized).loadOrCreateKey()
            _ = try CloudLocalStore(path: finalPaths.database.path, key: key)
            let mediaCopied = fileManager.fileExists(atPath: finalPaths.media.path)
            try writeMarker(
                Marker(
                    version: 1,
                    accountId: normalized,
                    databaseIntegrityVerified: true,
                    mediaCopied: mediaCopied,
                    completedAt: Date()
                ),
                to: markerURL
            )
            return LegacyAccountStorageMigrationResult(
                paths: finalPaths,
                copiedLegacyDatabase: true,
                copiedLegacyMedia: mediaCopied
            )
        }

        let stagingRoot = accountsRoot.appending(
            path: ".\(normalized).legacy-migration-v1",
            directoryHint: .isDirectory
        )
        if fileManager.fileExists(atPath: stagingRoot.path) {
            try fileManager.removeItem(at: stagingRoot)
        }
        try fileManager.createDirectory(
            at: stagingRoot,
            withIntermediateDirectories: false,
            attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication]
        )
        var stagingShouldBeRemoved = true
        defer {
            if stagingShouldBeRemoved, fileManager.fileExists(atPath: stagingRoot.path) {
                try? fileManager.removeItem(at: stagingRoot)
            }
        }

        let stagingDatabase = stagingRoot.appending(path: "cloud.sqlite")
        let hasLegacyDatabase = fileManager.fileExists(atPath: legacyDatabase.path)
        let accountKeyStore = try LocalDatabaseKeyStore.accountScoped(accountId: normalized)
        if hasLegacyDatabase {
            let legacyKey = try LocalDatabaseKeyStore.currentEnvironment().loadOrCreateKey()
            try accountKeyStore.installKeyIfAbsent(legacyKey)
            for suffix in ["", "-wal", "-shm"] {
                let source = URL(fileURLWithPath: legacyDatabase.path + suffix)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                try fileManager.copyItem(
                    at: source,
                    to: URL(fileURLWithPath: stagingDatabase.path + suffix)
                )
            }
        } else {
            _ = try accountKeyStore.loadOrCreateKey()
        }

        let legacyMedia = legacyRoot.appending(path: "media", directoryHint: .isDirectory)
        let stagingMedia = stagingRoot.appending(path: "media", directoryHint: .isDirectory)
        let copiedMedia = fileManager.fileExists(atPath: legacyMedia.path)
        if copiedMedia { try fileManager.copyItem(at: legacyMedia, to: stagingMedia) }
        else { try fileManager.createDirectory(at: stagingMedia, withIntermediateDirectories: false) }

        let legacyJobs = legacyRoot.appending(path: "background-media-jobs.json")
        if fileManager.fileExists(atPath: legacyJobs.path) {
            try fileManager.copyItem(
                at: legacyJobs,
                to: stagingRoot.appending(path: "background-media-jobs.json")
            )
        }

        let key = try accountKeyStore.loadOrCreateKey()
        // Opening runs SQLCipher's integrity check and every local schema migration. Only a verified
        // staging copy can be atomically promoted to the account's durable path.
        _ = try CloudLocalStore(path: stagingDatabase.path, key: key)
        let stagingMarker = stagingRoot.appending(path: "legacy-migration-v1.json")
        try writeMarker(
            Marker(
                version: 1,
                accountId: normalized,
                databaseIntegrityVerified: true,
                mediaCopied: copiedMedia,
                completedAt: Date()
            ),
            to: stagingMarker
        )
        try fileManager.moveItem(at: stagingRoot, to: finalPaths.root)
        stagingShouldBeRemoved = false
        _ = try AccountLocalStoreFactory.open(accountId: normalized)
        return LegacyAccountStorageMigrationResult(
            paths: finalPaths,
            copiedLegacyDatabase: hasLegacyDatabase,
            copiedLegacyMedia: copiedMedia
        )
    }

    private func legacyApplicationDirectory() throws -> URL {
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support.appending(
            path: LocalDatabaseKeyStore.usesTelegramFastUITestFixture ? "TojUITest" : "Toj",
            directoryHint: .isDirectory
        )
    }

    private func loadMarker(at url: URL) throws -> Marker? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(Marker.self, from: Data(contentsOf: url))
    }

    private func writeMarker(_ marker: Marker, to url: URL) throws {
        try JSONEncoder().encode(marker).write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}
