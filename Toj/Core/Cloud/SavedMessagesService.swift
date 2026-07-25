import Foundation

nonisolated protocol SavedMessagesProvisioningClient: Sendable {
    func ensureSavedMessages(token: String) async throws -> SavedDialogResponse
}

extension CloudAPI: SavedMessagesProvisioningClient {}

actor SavedMessagesService {
    private struct Scope: Equatable {
        let accountId: String
        let token: String
        let generation: UInt64
        let storeId: ObjectIdentifier
    }

    private struct InFlight {
        let id: UUID
        let scope: Scope
        let task: Task<String, Error>
    }

    private struct CancellationBarrier {
        let id: UUID
        let task: Task<Void, Never>
    }

    private var activeScope: Scope?
    private var inFlight: InFlight?
    private var cancellationBarrier: CancellationBarrier?

    func localDialogId(store: CloudLocalStore, accountId: String) async throws -> String? {
        try await store.savedMessagesDialogId(accountId: accountId)
    }

    /// Returns the encrypted local row first and coalesces callers only within one exact session.
    func ensure(
        api: any SavedMessagesProvisioningClient,
        store: CloudLocalStore,
        accountId: String,
        token: String,
        generation: UInt64
    ) async throws -> String {
        let scope = Scope(
            accountId: accountId,
            token: token,
            generation: generation,
            storeId: ObjectIdentifier(store)
        )
        try await transition(to: scope)
        try Task.checkCancellation()
        guard activeScope == scope else { throw SavedMessagesServiceError.staleSession }

        if let local = try await store.savedMessagesDialogId(accountId: accountId) {
            try Task.checkCancellation()
            guard activeScope == scope else { throw SavedMessagesServiceError.staleSession }
            return local
        }
        if let inFlight, inFlight.scope == scope {
            let dialogId = try await inFlight.task.value
            try Task.checkCancellation()
            guard activeScope == scope else { throw SavedMessagesServiceError.staleSession }
            return dialogId
        }

        let taskId = UUID()
        let task = Task {
            let response = try await api.ensureSavedMessages(token: token)
            guard response.type == "saved" else {
                throw SavedMessagesServiceError.invalidDialogType
            }
            // Cancellation is checked both here and inside CloudLocalStore's actor before SQL.
            try Task.checkCancellation()
            try await store.ensureSavedDialog(
                dialogId: response.dialogId,
                accountId: accountId,
                updatedAt: nil
            )
            try Task.checkCancellation()
            return response.dialogId
        }
        inFlight = InFlight(id: taskId, scope: scope, task: task)
        do {
            let dialogId = try await task.value
            try Task.checkCancellation()
            guard activeScope == scope else { throw SavedMessagesServiceError.staleSession }
            if inFlight?.id == taskId { inFlight = nil }
            return dialogId
        } catch {
            if inFlight?.id == taskId { inFlight = nil }
            throw error
        }
    }

    /// Invalidates the active session and does not return until its exact provisioning task exits.
    func reset() async {
        activeScope = nil
        await cancelAndAwaitInFlight()
        await awaitCancellationBarrier()
    }

    private func transition(to scope: Scope) async throws {
        if activeScope != scope {
            activeScope = scope
            await cancelAndAwaitInFlight()
        }
        await awaitCancellationBarrier()
        try Task.checkCancellation()
        guard activeScope == scope else { throw SavedMessagesServiceError.staleSession }
    }

    private func cancelAndAwaitInFlight() async {
        guard let previous = inFlight else { return }
        inFlight = nil
        previous.task.cancel()
        let barrierId = UUID()
        let barrierTask = Task {
            _ = await previous.task.result
        }
        cancellationBarrier = CancellationBarrier(id: barrierId, task: barrierTask)
        await barrierTask.value
        if cancellationBarrier?.id == barrierId { cancellationBarrier = nil }
    }

    private func awaitCancellationBarrier() async {
        guard let barrier = cancellationBarrier else { return }
        await barrier.task.value
        if cancellationBarrier?.id == barrier.id { cancellationBarrier = nil }
    }
}

nonisolated enum SavedMessagesServiceError: LocalizedError, Sendable {
    case invalidDialogType
    case staleSession

    var errorDescription: String? {
        switch self {
        case .invalidDialogType:
            String(localized: "The server returned an invalid Saved Messages conversation.")
        case .staleSession:
            String(localized: "The Saved Messages session changed before setup completed.")
        }
    }
}
