import Foundation

/// Session-scoped local-first draft engine. CloudAppModel supplies session/capability changes, while
/// this actor owns write ordering, debounce, idempotent acknowledgements, and retry timing.
actor DraftSyncCoordinator {
    enum FlushResult: Equatable, Sendable {
        case synced
        case unsupported
        case retryable
        case suspended
        case terminal

        var isSynced: Bool { self == .synced }
    }

    enum FlushReason: Sendable {
        case idle
        case navigation
        case background
        case attachmentChanged
        case replyChanged

        var isImmediate: Bool {
            self != .idle
        }
    }

    private let api: CloudAPI
    private var store: CloudLocalStore?
    private var session: CloudSession?
    private var cloudEnabled = false
    private var suspended = false
    private var sessionGeneration: UInt64 = 0
    private var debounceTasks: [String: Task<Void, Never>] = [:]
    private var debounceTokens: [String: UUID] = [:]
    private var retryTask: Task<Void, Never>?
    private var flushingDialogs: Set<String> = []
    private var flushWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var stagingDialogs: Set<String> = []
    private var stagingWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var activeUploads = 0
    private struct TrackedWork {
        let cancel: @Sendable () -> Void
        let wait: @Sendable () async -> Void
    }
    private var trackedWork: [UUID: TrackedWork] = [:]
    private struct UploadWaiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }
    private var uploadWaiters: [UploadWaiter] = []

    init(api: CloudAPI) {
        self.api = api
    }

    deinit {
        for task in debounceTasks.values { task.cancel() }
        retryTask?.cancel()
    }

    func configure(
        store: CloudLocalStore?,
        session: CloudSession?,
        cloudEnabled: Bool
    ) {
        if self.session != session {
            sessionGeneration &+= 1
        }
        self.store = store
        self.session = session
        self.cloudEnabled = cloudEnabled
        suspended = session == nil
        if session == nil {
            for task in debounceTasks.values { task.cancel() }
            debounceTasks.removeAll()
            debounceTokens.removeAll()
            retryTask?.cancel()
            retryTask = nil
        } else if cloudEnabled {
            scheduleRetry(after: 0)
        }
    }

    /// Quiesces every coordinator-owned operation before the encrypted database is destroyed.
    /// Clearing the references first ensures no newly resumed waiter can reach the old account.
    func cancelAndWait() async {
        sessionGeneration &+= 1
        suspended = true
        cloudEnabled = false
        store = nil
        session = nil

        let debounce = Array(debounceTasks.values)
        debounceTasks.removeAll()
        debounceTokens.removeAll()
        let retry = retryTask
        retryTask = nil
        for task in debounce { task.cancel() }
        retry?.cancel()

        let active = Array(trackedWork.values)
        trackedWork.removeAll()
        for work in active { work.cancel() }

        let flushContinuations = flushWaiters.values.flatMap { $0 }
        flushWaiters.removeAll()
        flushingDialogs.removeAll()
        for waiter in flushContinuations { waiter.resume() }
        let stagingContinuations = stagingWaiters.values.flatMap { $0 }
        stagingWaiters.removeAll()
        stagingDialogs.removeAll()
        for waiter in stagingContinuations { waiter.resume() }

        let permitContinuations = uploadWaiters
        uploadWaiters.removeAll()
        for waiter in permitContinuations {
            waiter.continuation.resume(throwing: CancellationError())
        }

        for task in debounce { await task.value }
        if let retry { await retry.value }
        for work in active { await work.wait() }
        activeUploads = 0
    }

    @discardableResult
    func mutate(
        dialogId: String,
        text: String,
        replyToMsgId: Int64?,
        replyPreview: CloudDraftReplyPreview?,
        mentions: [CloudMention],
        reason: FlushReason = .idle
    ) async throws -> LocalDraft {
        guard let store, let session else { throw CancellationError() }
        let generation = sessionGeneration
        let draft = try await store.saveLocalDraft(
            accountId: session.accountId,
            dialogId: dialogId,
            text: text,
            replyToMsgId: replyToMsgId,
            replyPreview: replyPreview,
            mentions: mentions
        )
        try ensureCurrent(generation)
        scheduleFlush(dialogId: dialogId, reason: reason)
        return draft
    }

    func currentDraft(dialogId: String) async throws -> LocalDraft? {
        guard let store, let session else { return nil }
        let generation = sessionGeneration
        let draft = try await store.loadDraft(accountId: session.accountId, dialogId: dialogId)
        try ensureCurrent(generation)
        return draft
    }

    /// Navigation/background callers await this so the latest local generation is durably queued
    /// and, when supported, gets an immediate network attempt.
    @discardableResult
    func flush(dialogId: String, force: Bool = false) async -> FlushResult {
        debounceTasks[dialogId]?.cancel()
        debounceTasks[dialogId] = nil
        debounceTokens[dialogId] = nil
        guard cloudEnabled else { return .unsupported }
        guard !suspended, let store, let session else { return .suspended }
        let generation = sessionGeneration
        guard await acquireFlushSlot(dialogId: dialogId) else { return .retryable }
        defer { releaseFlushSlot(dialogId: dialogId) }
        var attemptedMutation: PendingDraftMutation?
        do {
            guard let pending = try await store.pendingDraftMutation(
                accountId: session.accountId,
                dialogId: dialogId
            ) else {
                return .synced
            }
            try ensureCurrent(generation)
            guard !pending.terminal else { return .terminal }
            // A staged attachment deliberately holds the cloud mutation until all chips are ready,
            // preventing a remote device from seeing a silently incomplete album.
            let visible = try await store.loadDraft(
                accountId: session.accountId,
                dialogId: dialogId
            )
            try ensureCurrent(generation)
            guard visible?.attachments.contains(where: { $0.state != "ready" }) != true else {
                return .retryable
            }
            let mutation: PendingDraftMutation
            if force {
                mutation = pending
            } else {
                let ready = try await store.pendingDraftMutationsReady(limit: 100)
                try ensureCurrent(generation)
                guard let due = ready.last(where: { $0.dialogId == dialogId }) else {
                    return .retryable
                }
                mutation = due
            }
            attemptedMutation = mutation
            let response = try await runTracked {
                try await self.api.updateDraft(
                    dialogId: mutation.dialogId,
                    operationId: mutation.operationId,
                    state: mutation.state,
                    text: mutation.text,
                    replyToMsgId: mutation.replyToMsgId,
                    mentions: mutation.mentions,
                    attachments: mutation.attachments,
                    token: session.token
                )
            }
            try ensureCurrent(generation)
            try await store.acknowledgeDraftMutation(
                response,
                accountId: session.accountId,
                attemptedOperationId: mutation.operationId
            )
            try ensureCurrent(generation)
            return .synced
        } catch is CancellationError {
            return .suspended
        } catch {
            let disposition = cloudOperationFailureDisposition(
                error,
                serverAdvertisesFeature: cloudEnabled
            )
            if let attemptedMutation {
                await recordFailure(
                    error,
                    mutation: attemptedMutation,
                    store: store,
                    session: session
                )
            }
            switch disposition {
            case .authenticationRequired: return .suspended
            case .unsupportedServer: return .unsupported
            case .transient: return .retryable
            case .permanent: return .terminal
            }
        }
    }

    /// Publishes the immutable draft operation captured by an optimistic send. New composer edits
    /// may coalesce independently without changing this dependency.
    func flushDependency(operationId: String) async -> FlushResult {
        guard cloudEnabled else { return .unsupported }
        guard !suspended, let store, let session else { return .suspended }
        let generation = sessionGeneration
        do {
            guard let mutation = try await store.pendingDraftDependency(operationId: operationId)
            else { return .synced }
            try ensureCurrent(generation)
            guard !mutation.terminal else { return .terminal }
            let response = try await runTracked {
                try await self.api.updateDraft(
                    dialogId: mutation.dialogId,
                    operationId: mutation.operationId,
                    state: mutation.state,
                    text: mutation.text,
                    replyToMsgId: mutation.replyToMsgId,
                    mentions: mutation.mentions,
                    attachments: mutation.attachments,
                    token: session.token
                )
            }
            try ensureCurrent(generation)
            try await store.acknowledgeDraftDependency(
                response,
                accountId: session.accountId,
                attemptedOperationId: operationId
            )
            try ensureCurrent(generation)
            return .synced
        } catch is CancellationError {
            return .suspended
        } catch {
            let disposition = cloudOperationFailureDisposition(
                error,
                serverAdvertisesFeature: cloudEnabled
            )
            switch disposition {
            case .authenticationRequired:
                suspended = true
                retryTask?.cancel()
            case .unsupportedServer:
                cloudEnabled = false
            case let .transient(delay):
                try? await store.markDraftDependencyFailed(
                    operationId: operationId,
                    error: error.localizedDescription,
                    retryAfter: delay ?? 2
                )
            case .permanent:
                try? await store.markDraftDependencyFailed(
                    operationId: operationId,
                    error: error.localizedDescription,
                    retryAfter: nil,
                    terminal: true
                )
            }
            switch disposition {
            case .authenticationRequired: return .suspended
            case .unsupportedServer: return .unsupported
            case .transient: return .retryable
            case .permanent: return .terminal
            }
        }
    }

    func flushAll(reason: FlushReason) async {
        guard let store, let session else { return }
        let dialogIds: [String]
        if reason.isImmediate {
            dialogIds = (try? await store.pendingDraftDialogIds(accountId: session.accountId)) ?? []
        } else {
            let pending = (try? await store.pendingDraftMutationsReady(limit: 100)) ?? []
            dialogIds = Array(Set(pending.map(\.dialogId))).sorted()
        }
        for dialogId in dialogIds {
            if Task.isCancelled { return }
            guard await flush(dialogId: dialogId, force: reason.isImmediate) == .synced else { break }
        }
        if reason == .background {
            retryTask?.cancel()
            retryTask = nil
        }
    }

    /// Sending must publish the attempted operation before asking the server to consume it. This
    /// closes the offline/relaunch race where a message could arrive before its draft generation.
    func flushBeforeSend(dialogId: String) async -> LocalDraft? {
        guard let store, let session else { return nil }
        let before = try? await store.loadDraft(accountId: session.accountId, dialogId: dialogId)
        guard cloudEnabled else { return before }
        guard await flush(dialogId: dialogId, force: true) == .synced else { return nil }
        return try? await store.loadDraft(accountId: session.accountId, dialogId: dialogId)
    }

    func suspendRetries() {
        suspended = true
        retryTask?.cancel()
        retryTask = nil
    }

    func resumeRetries() {
        guard session != nil else { return }
        suspended = false
        if cloudEnabled { scheduleRetry(after: 0) }
    }

    /// Upload callers wrap the existing resumable engine here. Continuations enforce a hard
    /// session-wide maximum of two draft attachment uploads without blocking any main-actor work.
    func withAttachmentUploadPermit<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let generation = sessionGeneration
        try await acquireUploadPermit()
        defer { releaseUploadPermit() }
        try Task.checkCancellation()
        try ensureCurrent(generation)
        let result = try await runTracked(operation)
        try ensureCurrent(generation)
        return result
    }

    func withDialogStaging<T: Sendable>(
        dialogId: String,
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let generation = sessionGeneration
        while stagingDialogs.contains(dialogId) {
            await withCheckedContinuation { continuation in
                stagingWaiters[dialogId, default: []].append(continuation)
            }
            try Task.checkCancellation()
            try ensureCurrent(generation)
        }
        stagingDialogs.insert(dialogId)
        defer {
            stagingDialogs.remove(dialogId)
            let waiters = stagingWaiters.removeValue(forKey: dialogId) ?? []
            for waiter in waiters { waiter.resume() }
        }
        let result = try await runTracked(operation)
        try ensureCurrent(generation)
        return result
    }

    private func scheduleFlush(dialogId: String, reason: FlushReason) {
        debounceTasks[dialogId]?.cancel()
        let token = UUID()
        debounceTokens[dialogId] = token
        let delay: UInt64 = reason.isImmediate ? 0 : 600_000_000
        debounceTasks[dialogId] = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: delay)
            }
            guard !Task.isCancelled else { return }
            await self?.runScheduledFlush(
                dialogId: dialogId,
                reason: reason,
                token: token
            )
        }
    }

    private func runScheduledFlush(
        dialogId: String,
        reason: FlushReason,
        token: UUID
    ) async {
        guard !Task.isCancelled, debounceTokens[dialogId] == token else { return }
        debounceTasks[dialogId] = nil
        debounceTokens[dialogId] = nil
        _ = await flush(dialogId: dialogId, force: reason.isImmediate)
    }

    private func recordFailure(
        _ error: Error,
        mutation: PendingDraftMutation,
        store: CloudLocalStore,
        session: CloudSession
    ) async {
        let disposition = cloudOperationFailureDisposition(error, serverAdvertisesFeature: cloudEnabled)
        switch disposition {
        case .authenticationRequired:
            suspended = true
            retryTask?.cancel()
            // Authentication can be restored. Durable work remains non-terminal and queued.
        case .unsupportedServer:
            // Local persistence remains fully active; capability refresh may enable sync later.
            cloudEnabled = false
        case let .transient(serverDelay):
            let delay = serverDelay ?? min(60, pow(2, Double(min(mutation.retryCount + 1, 6))))
            try? await store.markDraftMutationFailed(
                accountId: session.accountId,
                dialogId: mutation.dialogId,
                operationId: mutation.operationId,
                error: error.localizedDescription,
                retryAfter: delay,
                terminal: false
            )
            scheduleRetry(after: delay)
        case .permanent:
            try? await store.markDraftMutationFailed(
                accountId: session.accountId,
                dialogId: mutation.dialogId,
                operationId: mutation.operationId,
                error: error.localizedDescription,
                retryAfter: nil,
                terminal: true
            )
        }
    }

    private func scheduleRetry(after delay: TimeInterval) {
        guard cloudEnabled, !suspended else { return }
        retryTask?.cancel()
        retryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }
            guard !Task.isCancelled, let self else { return }
            await self.drainReadyMutations()
        }
    }

    private func drainReadyMutations() async {
        guard cloudEnabled, !suspended, let store else { return }
        let mutations = (try? await store.pendingDraftMutationsReady(limit: 100)) ?? []
        for dialogId in Set(mutations.map(\.dialogId)).sorted() {
            if Task.isCancelled { return }
            guard await flush(dialogId: dialogId) == .synced else { break }
        }
        if let delay = try? await store.nextPendingDraftDelay() {
            scheduleRetry(after: max(0.25, delay))
        }
    }

    private func acquireFlushSlot(dialogId: String) async -> Bool {
        while flushingDialogs.contains(dialogId) {
            await withCheckedContinuation { continuation in
                flushWaiters[dialogId, default: []].append(continuation)
            }
            if Task.isCancelled { return false }
        }
        flushingDialogs.insert(dialogId)
        return true
    }

    private func releaseFlushSlot(dialogId: String) {
        flushingDialogs.remove(dialogId)
        let waiters = flushWaiters.removeValue(forKey: dialogId) ?? []
        for waiter in waiters { waiter.resume() }
    }

    private func acquireUploadPermit() async throws {
        try Task.checkCancellation()
        if activeUploads < 2 {
            activeUploads += 1
            return
        }
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                uploadWaiters.append(UploadWaiter(id: id, continuation: continuation))
            }
        } onCancel: {
            Task { await self.cancelUploadWaiter(id: id) }
        }
    }

    private func releaseUploadPermit() {
        if !uploadWaiters.isEmpty {
            uploadWaiters.removeFirst().continuation.resume()
        } else {
            activeUploads = max(0, activeUploads - 1)
        }
    }

    private func cancelUploadWaiter(id: UUID) {
        guard let index = uploadWaiters.firstIndex(where: { $0.id == id }) else { return }
        let waiter = uploadWaiters.remove(at: index)
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func ensureCurrent(_ generation: UInt64) throws {
        guard generation == sessionGeneration, store != nil, session != nil else {
            throw CancellationError()
        }
    }

    private func runTracked<T: Sendable>(
        _ operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        let id = UUID()
        let task = Task { try await operation() }
        trackedWork[id] = TrackedWork(
            cancel: { task.cancel() },
            wait: { _ = await task.result }
        )
        defer { trackedWork[id] = nil }
        return try await task.value
    }
}
