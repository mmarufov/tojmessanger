import Foundation

nonisolated struct DialogPreferencesDrainResult: Equatable, Sendable {
    var acceptedCount = 0
    var retryAfter: TimeInterval?
    var authenticationRequired = false
    var permanentErrors: [String] = []

    mutating func recordRetry(after delay: TimeInterval) {
        retryAfter = min(retryAfter ?? delay, delay)
    }
}

/// Owns the durable preference upload lane. The SQLCipher outbox remains the source of truth, so
/// actor cancellation, request timeouts, and process death cannot lose an optimistic user action.
actor DialogPreferencesCoordinator {
    private let api: CloudAPI
    private var drainInFlight = false

    init(api: CloudAPI) {
        self.api = api
    }

    var hasActiveDrain: Bool { drainInFlight }

    @discardableResult
    func queue(
        store: CloudLocalStore,
        accountId: String,
        dialogId: String,
        field: DialogPreferenceField,
        desiredValue: Bool? = nil
    ) async throws -> PendingDialogPreferenceMutation? {
        try await store.queueDialogPreference(
            accountId: accountId,
            dialogId: dialogId,
            field: field,
            desiredValue: desiredValue
        )
    }

    func drain(
        store: CloudLocalStore,
        accountId: String,
        token: String,
        serverAdvertisesFeature: Bool
    ) async throws -> DialogPreferencesDrainResult {
        guard !drainInFlight else { return DialogPreferencesDrainResult() }
        drainInFlight = true
        defer { drainInFlight = false }

        var result = DialogPreferencesDrainResult()
        var processed = 0
        while processed < 200 {
            try Task.checkCancellation()
            let items = try await store.pendingDialogPreferencesReady(
                accountId: accountId,
                limit: min(50, 200 - processed)
            )
            guard !items.isEmpty else { break }

            for item in items {
                try Task.checkCancellation()
                processed += 1
                do {
                    let response = try await api.updateDialogPreferences(
                        dialogId: item.dialogId,
                        clientMutationId: item.clientMutationId,
                        pinned: item.field == .pinned ? item.desiredValue : nil,
                        muted: item.field == .muted ? item.desiredValue : nil,
                        archived: item.field == .archived ? item.desiredValue : nil,
                        token: token
                    )
                    try await store.acknowledgeDialogPreference(
                        clientMutationId: item.clientMutationId,
                        pts: response.pts,
                        preferences: response.preferences,
                        accountId: accountId
                    )
                    result.acceptedCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    let disposition = dialogPreferenceFailureDisposition(
                        error,
                        serverAdvertisesFeature: serverAdvertisesFeature
                    )
                    switch disposition {
                    case let .transient(serverRetry):
                        let delay = serverRetry ?? Self.retryDelay(
                            forRetryCount: item.retryCount + 1
                        )
                        try await store.failDialogPreference(
                            accountId: accountId,
                            clientMutationId: item.clientMutationId,
                            retryAfter: delay,
                            error: error.localizedDescription,
                            terminal: false
                        )
                        result.recordRetry(after: delay)
                    case .authenticationRequired:
                        let delay: TimeInterval = 30
                        try await store.failDialogPreference(
                            accountId: accountId,
                            clientMutationId: item.clientMutationId,
                            retryAfter: delay,
                            error: "Sign in required",
                            terminal: false
                        )
                        result.authenticationRequired = true
                        result.recordRetry(after: delay)
                    case .unsupportedServer, .permanent:
                        try await store.failDialogPreference(
                            accountId: accountId,
                            clientMutationId: item.clientMutationId,
                            retryAfter: nil,
                            error: error.localizedDescription,
                            terminal: true
                        )
                        result.permanentErrors.append(error.localizedDescription)
                    }
                }
            }
        }
        return result
    }

    nonisolated private static func retryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, retryCount - 1))))
    }
}

nonisolated func dialogPreferenceFailureDisposition(
    _ error: Error,
    serverAdvertisesFeature: Bool
) -> CloudFailureDisposition {
    if let apiError = error as? CloudAPIError, apiError.status == 403 {
        // The session is still valid, but this account can no longer mutate the dialog. Keeping the
        // optimistic overlay would lie indefinitely after removal or an access-policy change.
        return .permanent
    }
    return cloudOperationFailureDisposition(
        error,
        serverAdvertisesFeature: serverAdvertisesFeature
    )
}
