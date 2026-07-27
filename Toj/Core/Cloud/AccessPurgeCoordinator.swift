import Foundation

nonisolated struct AccessPurgeScope: Equatable, Sendable {
    let accountId: String
    let token: String
    let generation: UInt64
    let storeIdentity: ObjectIdentifier

    init(accountId: String, token: String, generation: UInt64, store: CloudLocalStore) {
        self.accountId = accountId
        self.token = token
        self.generation = generation
        self.storeIdentity = ObjectIdentifier(store)
    }
}

nonisolated struct AccessPurgeDrainResult: Equatable, Sendable {
    let finalized: Int
    let batches: Int
    let failed: Int

    init(finalized: Int, batches: Int, failed: Int = 0) {
        self.finalized = finalized
        self.batches = batches
        self.failed = failed
    }
}

enum AccessPurgeCoordinatorError: Error {
    case staleSession
}

/// Session-scoped, file-first revocation cleanup. The SQLCipher queue is authoritative and every
/// phase is idempotent, so process death can resume without making a revoked archive visible.
actor AccessPurgeCoordinator {
    private struct InFlight {
        let scope: AccessPurgeScope
        let task: Task<AccessPurgeDrainResult, Error>
    }

    private var activeScope: AccessPurgeScope?
    private var inFlight: InFlight?
    private var resetting = false

    func drain(
        scope: AccessPurgeScope,
        store: CloudLocalStore,
        mediaEngine: CloudMediaTransferEngine,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        invalidatePresentation: @escaping @MainActor @Sendable (AccessPurgeJob) async -> Void,
        purgeFilesOverride: (@Sendable (AccessPurgeJob) async throws -> Void)? = nil
    ) async throws -> AccessPurgeDrainResult {
        guard !resetting else { throw AccessPurgeCoordinatorError.staleSession }
        if activeScope != scope {
            activeScope = scope
            await cancelAndAwait()
        }
        if let inFlight, inFlight.scope == scope {
            return try await inFlight.task.value
        }

        let task = Task {
            var finalized = 0
            var batches = 0
            var failedJobIds: Set<String> = []
            while !Task.isCancelled {
                guard await isCurrent() else { throw AccessPurgeCoordinatorError.staleSession }
                let jobs = try await store.pendingAccessPurgeJobs(
                    limit: 20,
                    excluding: failedJobIds
                )
                if jobs.isEmpty { break }
                batches += 1
                for queuedJob in jobs {
                    do {
                        try Task.checkCancellation()
                        guard await isCurrent() else {
                            throw AccessPurgeCoordinatorError.staleSession
                        }
                        await invalidatePresentation(queuedJob)
                        try Task.checkCancellation()
                        guard await isCurrent() else {
                            throw AccessPurgeCoordinatorError.staleSession
                        }
                        let job: AccessPurgeJob
                        if queuedJob.phase == .staged {
                            guard let refreshed = try await store.refreshAccessPurgeJob(
                                id: queuedJob.id
                            ) else { continue }
                            job = refreshed
                        } else {
                            job = queuedJob
                        }
                        try Task.checkCancellation()
                        guard await isCurrent() else {
                            throw AccessPurgeCoordinatorError.staleSession
                        }
                        if job.phase == .staged {
                            if let purgeFilesOverride {
                                try await purgeFilesOverride(job)
                            } else {
                                try await mediaEngine.purgeRevokedAccess(
                                    allMediaIds: job.allMediaIds,
                                    purgeMediaIds: job.purgeMediaIds,
                                    encryptedPaths: job.encryptedPaths,
                                    localStore: store
                                )
                            }
                            try Task.checkCancellation()
                            guard await isCurrent() else {
                                throw AccessPurgeCoordinatorError.staleSession
                            }
                            try await store.markAccessPurgeFilesDeleted(id: job.id)
                        }
                        try Task.checkCancellation()
                        guard await isCurrent() else {
                            throw AccessPurgeCoordinatorError.staleSession
                        }
                        try await store.finalizeAccessPurge(id: job.id)
                        finalized += 1
                    } catch is CancellationError {
                        throw CancellationError()
                    } catch AccessPurgeCoordinatorError.staleSession {
                        throw AccessPurgeCoordinatorError.staleSession
                    } catch {
                        failedJobIds.insert(queuedJob.id)
                        try? await store.markAccessPurgeFailed(
                            id: queuedJob.id,
                            error: error.localizedDescription
                        )
                    }
                }
                await Task.yield()
            }
            return AccessPurgeDrainResult(
                finalized: finalized,
                batches: batches,
                failed: failedJobIds.count
            )
        }
        inFlight = InFlight(scope: scope, task: task)
        defer {
            if inFlight?.scope == scope {
                inFlight = nil
            }
        }
        return try await task.value
    }

    func reset() async {
        if resetting {
            _ = await inFlight?.task.result
            return
        }
        resetting = true
        activeScope = nil
        await cancelAndAwait()
        resetting = false
    }

    private func cancelAndAwait() async {
        let old = inFlight
        inFlight = nil
        old?.task.cancel()
        _ = await old?.task.result
    }
}
