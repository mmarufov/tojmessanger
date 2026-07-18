import CryptoKit
import XCTest
@testable import Toj

@MainActor
final class EncryptedProfilePhotoStoreTests: XCTestCase {
    func testRoamingOverrideCanBeReadBack() {
        let monitor = ReplicaNetworkMonitor.shared
        let original = monitor.cellularRoamingSetting()
        defer { monitor.setCellularRoaming(original) }

        monitor.setCellularRoaming(true)
        XCTAssertTrue(monitor.cellularRoamingSetting())
        monitor.setCellularRoaming(false)
        XCTAssertFalse(monitor.cellularRoamingSetting())
    }

    func testRoundTripUsesEncryptedBackupExcludedFile() async throws {
        try await withFixture { fixture in
            let photo = Data("local-profile-jpeg-payload-\(UUID().uuidString)".utf8)
            let didPersist = await EncryptedProfilePhotoStore.persistForTesting(
                photo,
                accountId: fixture.accountId,
                applicationSupportDirectory: fixture.supportRoot,
                masterKey: fixture.masterKey
            )
            let loaded = await EncryptedProfilePhotoStore.loadForTesting(
                accountId: fixture.accountId,
                applicationSupportDirectory: fixture.supportRoot,
                masterKey: fixture.masterKey
            )
            XCTAssertTrue(didPersist)
            XCTAssertEqual(loaded, photo)

            let url = encryptedURL(fixture: fixture)
            let stored = try Data(contentsOf: url)
            XCTAssertNil(stored.range(of: photo))
            XCTAssertEqual(
                try url.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup,
                true
            )
            #if !targetEnvironment(simulator)
            XCTAssertEqual(
                try FileManager.default.attributesOfItem(atPath: url.path)[.protectionKey]
                    as? FileProtectionType,
                .completeUntilFirstUserAuthentication
            )
            #endif

            let wrongKey = Data(repeating: 0x5A, count: 32)
            let loadedWithWrongKey = await EncryptedProfilePhotoStore.loadForTesting(
                accountId: fixture.accountId,
                applicationSupportDirectory: fixture.supportRoot,
                masterKey: wrongKey
            )
            XCTAssertNil(loadedWithWrongKey)
        }
    }

    func testLegacyPlaintextMigratesOnlyAfterEncryptedCopyIsReadable() async throws {
        try await withFixture { fixture in
            let photo = Data("legacy-profile-jpeg-payload-\(UUID().uuidString)".utf8)
            let legacyURL = legacyURL(fixture: fixture)
            try FileManager.default.createDirectory(
                at: legacyURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try photo.write(to: legacyURL, options: .atomic)

            let loaded = await EncryptedProfilePhotoStore.loadForTesting(
                accountId: fixture.accountId,
                applicationSupportDirectory: fixture.supportRoot,
                masterKey: fixture.masterKey
            )
            XCTAssertEqual(loaded, photo)
            XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

            let encryptedURL = encryptedURL(fixture: fixture)
            XCTAssertTrue(FileManager.default.fileExists(atPath: encryptedURL.path))
            XCTAssertNil(try Data(contentsOf: encryptedURL).range(of: photo))
        }
    }

    private func withFixture(
        _ body: (Fixture) async throws -> Void
    ) async throws {
        EncryptedProfilePhotoStore.beginAuthenticatedSession()
        let identifier = UUID().uuidString.lowercased()
        let fixture = Fixture(
            accountId: "profile-photo-test-\(identifier)",
            supportRoot: FileManager.default.temporaryDirectory
                .appending(path: "TojProfilePhotoTests", directoryHint: .isDirectory)
                .appending(path: identifier, directoryHint: .isDirectory),
            masterKey: Data(SHA256.hash(data: Data(identifier.utf8)))
        )
        do {
            try await body(fixture)
            let didCleanUp = await EncryptedProfilePhotoStore.persistForTesting(
                nil,
                accountId: fixture.accountId,
                applicationSupportDirectory: fixture.supportRoot,
                masterKey: fixture.masterKey
            )
            XCTAssertTrue(didCleanUp)
            try? FileManager.default.removeItem(at: fixture.supportRoot)
        } catch {
            _ = await EncryptedProfilePhotoStore.persistForTesting(
                nil,
                accountId: fixture.accountId,
                applicationSupportDirectory: fixture.supportRoot,
                masterKey: fixture.masterKey
            )
            try? FileManager.default.removeItem(at: fixture.supportRoot)
            throw error
        }
    }

    private func encryptedURL(fixture: Fixture) -> URL {
        let digest = SHA256.hash(data: Data(fixture.accountId.utf8))
        let fileName = digest.map { String(format: "%02x", $0) }.joined()
        return fixture.supportRoot
            .appending(path: "Toj", directoryHint: .isDirectory)
            .appending(path: "ProfilePhotos", directoryHint: .isDirectory)
            .appending(path: "\(fileName).tojprofile")
    }

    private func legacyURL(fixture: Fixture) -> URL {
        fixture.supportRoot
            .appending(path: "ProfilePhotos", directoryHint: .isDirectory)
            .appending(path: "\(fixture.accountId).jpg")
    }

    private struct Fixture {
        let accountId: String
        let supportRoot: URL
        let masterKey: Data
    }
}
