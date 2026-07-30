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
        let id: UUID
        let scope: AccessPurgeScope
        let task: Task<AccessPurgeDrainResult, Error>
    }

    private struct ScopeTransition {
        let id: UUID
        let target: AccessPurgeScope
        let task: Task<Void, Never>
    }

    private struct ResetBarrier {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var activeScope: AccessPurgeScope?
    private var inFlight: InFlight?
    private var scopeTransition: ScopeTransition?
    private var resetBarrier: ResetBarrier?

    func drain(
        scope: AccessPurgeScope,
        store: CloudLocalStore,
        mediaEngine: CloudMediaTransferEngine,
        isCurrent: @escaping @MainActor @Sendable () -> Bool,
        invalidatePresentation: @escaping @MainActor @Sendable (AccessPurgeJob) async -> Void,
        purgeFilesOverride: (@Sendable (AccessPurgeJob) async throws -> Void)? = nil
    ) async throws -> AccessPurgeDrainResult {
        while true {
            guard resetBarrier == nil else {
                throw AccessPurgeCoordinatorError.staleSession
            }
            if let transition = scopeTransition {
                await transition.task.value
                if scopeTransition?.id == transition.id {
                    activeScope = transition.target
                    scopeTransition = nil
                }
                continue
            }
            guard activeScope != scope else { break }

            let old = inFlight
            inFlight = nil
            old?.task.cancel()
            let id = UUID()
            let transitionTask = Task {
                _ = await old?.task.result
            }
            scopeTransition = ScopeTransition(
                id: id,
                target: scope,
                task: transitionTask
            )
            await transitionTask.value
            if scopeTransition?.id == id {
                activeScope = scope
                scopeTransition = nil
            }
        }
        if let inFlight, inFlight.scope == scope {
            return try await inFlight.task.value
        }

        let operationId = UUID()
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
        inFlight = InFlight(id: operationId, scope: scope, task: task)
        defer {
            if inFlight?.id == operationId {
                inFlight = nil
            }
        }
        return try await task.value
    }

    func reset() async {
        if let resetBarrier {
            await resetBarrier.task.value
            return
        }

        activeScope = nil
        let transition = scopeTransition
        scopeTransition = nil
        let old = inFlight
        inFlight = nil
        transition?.task.cancel()
        old?.task.cancel()

        let id = UUID()
        let task = Task {
            await transition?.task.value
            _ = await old?.task.result
        }
        resetBarrier = ResetBarrier(id: id, task: task)
        await task.value
        if resetBarrier?.id == id {
            resetBarrier = nil
        }
    }

    #if DEBUG
    func testHasResetBarrier() -> Bool {
        resetBarrier != nil
    }

    func testHasScopeTransition() -> Bool {
        scopeTransition != nil
    }
    #endif
}
