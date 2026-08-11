import Foundation

nonisolated enum ProfilePhotoSyncState: Equatable, Sendable {
    case localOnly
    case synced
    case pending
    case failed(String)
    case conflict
}

nonisolated enum ProfilePhotoCommitResult: Sendable {
    case idle
    case committed(CloudProfile)
    case retrying(String, TimeInterval)
    case failed(String)
    case conflict
    case cancelled
}

/// Owns the profile-photo mutation lane so it cannot become another collection of ad-hoc
/// `CloudAppModel` flags. The SQLCipher store remains the source of truth across process death.
actor ProfilePhotoSyncCoordinator {
    private let api: CloudAPI
    private let mediaEngine: CloudMediaTransferEngine
    private var store: CloudLocalStore?
    private var session: CloudSession?
    private var generation: UInt64 = 0
    private var enabled = false

    init(api: CloudAPI, mediaEngine: CloudMediaTransferEngine) {
        self.api = api
        self.mediaEngine = mediaEngine
    }

    func configure(store: CloudLocalStore?, session: CloudSession?, enabled: Bool) {
        generation &+= 1
        self.store = store
        self.session = session
        self.enabled = enabled
    }

    func pending() async -> PendingProfilePhotoMutation? {
        guard let store, let accountId = session?.accountId else { return nil }
        return try? await store.pendingProfilePhotoMutation(accountId: accountId)
    }

    func stageSet(
        prepared: PreparedMediaUpload,
        baseRevision: Int64,
        source: String = "user"
    ) async throws -> PendingProfilePhotoMutation {
        guard enabled, let store, let accountId = session?.accountId else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        let previous = try await store.pendingProfilePhotoMutation(accountId: accountId)
        let previousTransfer: MediaTransferRecord?
        if let transferId = previous?.transferId {
            previousTransfer = try await store.mediaTransfer(id: transferId)
        } else {
            previousTransfer = nil
        }
        do {
            let mutation = try await store.stageProfilePhotoSet(
                accountId: accountId,
                prepared: prepared,
                basePhotoRevision: baseRevision,
                source: source
            )
            if let previousTransfer { await mediaEngine.discardTransfer(previousTransfer) }
            return mutation
        } catch {
            await mediaEngine.discardPrepared(prepared)
            throw error
        }
    }

    func stageRemoval(baseRevision: Int64) async throws -> PendingProfilePhotoMutation {
        guard enabled, let store, let accountId = session?.accountId else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        let previous = try await store.pendingProfilePhotoMutation(accountId: accountId)
        let previousTransfer: MediaTransferRecord?
        if let transferId = previous?.transferId {
            previousTransfer = try await store.mediaTransfer(id: transferId)
        } else {
            previousTransfer = nil
        }
        let mutation = try await store.stageProfilePhotoRemoval(
            accountId: accountId,
            basePhotoRevision: baseRevision
        )
        if let previousTransfer { await mediaEngine.discardTransfer(previousTransfer) }
        return mutation
    }

    func markUploaded(transferId: String, mediaId: String) async throws {
        guard let store else { throw ProfilePhotoCoordinatorError.unavailable }
        try await store.markProfilePhotoUploaded(transferId: transferId, mediaId: mediaId)
    }

    func commitReady() async -> ProfilePhotoCommitResult {
        guard enabled, let store, let session else { return .idle }
        let expectedGeneration = generation
        guard let mutation = try? await store.readyProfilePhotoMutation(accountId: session.accountId) else {
            return .idle
        }
        do {
            let response = try await api.updateProfilePhoto(
                mediaId: mutation.operation == "remove" ? nil : mutation.mediaId,
                clientMutationId: mutation.clientMutationId,
                basePhotoRevision: mutation.basePhotoRevision,
                token: session.token
            )
            try Task.checkCancellation()
            guard generation == expectedGeneration,
                  self.session?.accountId == session.accountId,
                  self.session?.token == session.token,
                  self.store === store
            else { return .cancelled }

            let transfer: MediaTransferRecord?
            if let transferId = mutation.transferId {
                transfer = try? await store.mediaTransfer(id: transferId)
            } else {
                transfer = nil
            }
            if let transfer {
                let promoted = await mediaEngine.finishUpload(transfer, localStore: store)
                if !promoted { await mediaEngine.discardTransfer(transfer) }
            }
            _ = try await store.completeProfilePhotoMutation(
                accountId: session.accountId,
                profile: response.profile
            )
            return .committed(response.profile)
        } catch is CancellationError {
            return .cancelled
        } catch {
            guard generation == expectedGeneration else { return .cancelled }
            if let apiError = error as? CloudAPIError,
               apiError.status == 409 || apiError.code == "stale_profile_photo" {
                try? await store.failProfilePhotoMutation(
                    accountId: session.accountId,
                    error: apiError.localizedDescription,
                    retryAfter: nil,
                    conflict: true
                )
                return .conflict
            }
            switch cloudFailureDisposition(error) {
            case let .transient(serverDelay):
                let delay = serverDelay ?? min(300, pow(2, Double(mutation.retryCount + 1)))
                try? await store.failProfilePhotoMutation(
                    accountId: session.accountId,
                    error: error.localizedDescription,
                    retryAfter: delay
                )
                return .retrying(error.localizedDescription, delay)
            case .authenticationRequired:
                return .cancelled
            case .unsupportedServer:
                return .failed(String(localized: "Profile photo sync is unavailable."))
            case .permanent:
                try? await store.failProfilePhotoMutation(
                    accountId: session.accountId,
                    error: error.localizedDescription,
                    retryAfter: nil,
                    terminal: true
                )
                return .failed(error.localizedDescription)
            }
        }
    }

    func useCloudPhoto() async throws -> CloudProfile {
        guard let store, let session else { throw ProfilePhotoCoordinatorError.unavailable }
        let profile = try await api.getProfile(token: session.token)
        let pending = try await store.pendingProfilePhotoMutation(accountId: session.accountId)
        let transfer: MediaTransferRecord?
        if let transferId = pending?.transferId {
            transfer = try await store.mediaTransfer(id: transferId)
        } else {
            transfer = nil
        }
        _ = try await store.discardProfilePhotoMutation(accountId: session.accountId)
        if let transfer { await mediaEngine.discardTransfer(transfer) }
        try await store.saveProfile(profile)
        return profile
    }

    func retryMine() async throws -> CloudProfile {
        guard let store, let session else { throw ProfilePhotoCoordinatorError.unavailable }
        let cloud = try await api.getProfile(token: session.token)
        try await store.saveProfile(cloud)
        try await store.rebaseProfilePhotoMutation(
            accountId: session.accountId,
            baseRevision: cloud.photoRevision
        )
        return cloud
    }

    func retryFailed() async throws {
        guard let store, let accountId = session?.accountId else {
            throw ProfilePhotoCoordinatorError.unavailable
        }
        try await store.retryProfilePhotoMutation(accountId: accountId)
    }

    func discard() async {
        guard let store, let accountId = session?.accountId else { return }
        let pending = try? await store.pendingProfilePhotoMutation(accountId: accountId)
        let transfer: MediaTransferRecord?
        if let transferId = pending?.transferId {
            transfer = try? await store.mediaTransfer(id: transferId)
        } else {
            transfer = nil
        }
        _ = try? await store.discardProfilePhotoMutation(accountId: accountId)
        if let transfer { await mediaEngine.discardTransfer(transfer) }
    }
}

nonisolated enum ProfilePhotoCoordinatorError: Error, LocalizedError {
    case unavailable

    var errorDescription: String? {
        String(localized: "Profile photo sync is unavailable.")
    }
}
