import Foundation

nonisolated struct DialogPreferencesDrainResult: Equatable, Sendable {
    var acceptedCount = 0
    var retryAfter: TimeInterval?
    var authenticationRequired = false
    var capabilityRefreshRequired = false
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
    private var activeAccountId: String?
    private var activeSessionGeneration: UInt64?
    private var activeRequest: Task<DialogPreferencesResponse, Error>?
    private var drainWaiters: [CheckedContinuation<Void, Never>] = []

    init(api: CloudAPI) {
        self.api = api
    }

    var hasActiveDrain: Bool { drainInFlight }

    func cancelAndWait() async {
        activeAccountId = nil
        activeSessionGeneration = nil
        activeRequest?.cancel()
        guard drainInFlight else { return }
        await withCheckedContinuation { continuation in
            drainWaiters.append(continuation)
        }
    }

    private func validate(accountId: String, sessionGeneration: UInt64) throws {
        try Task.checkCancellation()
        guard
            activeAccountId == accountId,
            activeSessionGeneration == sessionGeneration
        else {
            throw CancellationError()
        }
    }

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
        serverAdvertisesFeature: Bool,
        sessionGeneration: UInt64 = 0
    ) async throws -> DialogPreferencesDrainResult {
        guard !drainInFlight else { return DialogPreferencesDrainResult() }
        drainInFlight = true
        activeAccountId = accountId
        activeSessionGeneration = sessionGeneration
        defer {
            activeRequest = nil
            activeAccountId = nil
            activeSessionGeneration = nil
            drainInFlight = false
            let waiters = drainWaiters
            drainWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }

        var result = DialogPreferencesDrainResult()
        var processed = 0
        while processed < 200 {
            try validate(accountId: accountId, sessionGeneration: sessionGeneration)
            let items = try await store.pendingDialogPreferencesReady(
                accountId: accountId,
                limit: min(50, 200 - processed)
            )
            try validate(accountId: accountId, sessionGeneration: sessionGeneration)
            guard !items.isEmpty else { break }

            for item in items {
                try validate(accountId: accountId, sessionGeneration: sessionGeneration)
                processed += 1
                do {
                    try await store.markDialogPreferenceAttempted(
                        accountId: accountId,
                        clientMutationId: item.clientMutationId
                    )
                    try validate(accountId: accountId, sessionGeneration: sessionGeneration)
                    let request = Task {
                        try await api.updateDialogPreferences(
                            dialogId: item.dialogId,
                            clientMutationId: item.clientMutationId,
                            pinned: item.field == .pinned ? item.desiredValue : nil,
                            muted: item.field == .muted ? item.desiredValue : nil,
                            archived: item.field == .archived ? item.desiredValue : nil,
                            token: token
                        )
                    }
                    activeRequest = request
                    let response = try await request.value
                    activeRequest = nil
                    try validate(accountId: accountId, sessionGeneration: sessionGeneration)
                    try await store.acknowledgeDialogPreference(
                        clientMutationId: item.clientMutationId,
                        pts: response.pts,
                        preferences: response.preferences,
                        accountId: accountId
                    )
                    try validate(accountId: accountId, sessionGeneration: sessionGeneration)
                    result.acceptedCount += 1
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as URLError where error.code == .cancelled {
                    throw CancellationError()
                } catch {
                    // A request can finish concurrently with logout or an account switch. Never
                    // touch the old account's SQLCipher outbox after the session was invalidated.
                    try validate(accountId: accountId, sessionGeneration: sessionGeneration)
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
                        return result
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
                        return result
                    case .unsupportedServer:
                        let delay: TimeInterval = 30
                        try await store.failDialogPreference(
                            accountId: accountId,
                            clientMutationId: item.clientMutationId,
                            retryAfter: delay,
                            error: "Server capability changed",
                            terminal: false,
                            dormant: true
                        )
                        result.capabilityRefreshRequired = true
                        result.recordRetry(after: delay)
                        return result
                    case .permanent:
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
    if let apiError = error as? CloudAPIError,
       apiError.status == 404,
       apiError.code == "capability_unavailable" {
        // The rollout route hard-404s when capability or server behavior is withdrawn. Refresh
        // negotiation and retain the durable intent; membership failures use explicit 403/410.
        return .unsupportedServer
    }
    if let apiError = error as? CloudAPIError, apiError.status == 404 {
        return .permanent
    }
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
