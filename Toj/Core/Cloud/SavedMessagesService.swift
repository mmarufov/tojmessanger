import Foundation

actor SavedMessagesService {
    private var inFlight: Task<String, Error>?

    func localDialogId(store: CloudLocalStore, accountId: String) async throws -> String? {
        try await store.savedMessagesDialogId(accountId: accountId)
    }

    /// Returns the encrypted local row first and coalesces every concurrent provisioning caller.
    func ensure(
        api: CloudAPI,
        store: CloudLocalStore,
        accountId: String,
        token: String
    ) async throws -> String {
        if let local = try await store.savedMessagesDialogId(accountId: accountId) {
            return local
        }
        if let inFlight {
            return try await inFlight.value
        }
        let task = Task {
            let response = try await api.ensureSavedMessages(token: token)
            guard response.type == "saved" else {
                throw SavedMessagesServiceError.invalidDialogType
            }
            try await store.ensureSavedDialog(
                dialogId: response.dialogId,
                accountId: accountId,
                updatedAt: nil
            )
            return response.dialogId
        }
        inFlight = task
        defer { inFlight = nil }
        return try await task.value
    }

    func reset() {
        inFlight?.cancel()
        inFlight = nil
    }
}

nonisolated enum SavedMessagesServiceError: LocalizedError, Sendable {
    case invalidDialogType

    var errorDescription: String? {
        switch self {
        case .invalidDialogType:
            String(localized: "The server returned an invalid Saved Messages conversation.")
        }
    }
}
