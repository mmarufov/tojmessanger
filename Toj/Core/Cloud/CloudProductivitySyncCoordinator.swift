import Foundation

nonisolated struct AccountOperationContext: Sendable {
  let accountId: String
  let deviceId: String
  let token: String
  let generation: UInt64
  let store: CloudLocalStore

  var storeIdentity: ObjectIdentifier { ObjectIdentifier(store) }
}

nonisolated enum CloudProductivityRefreshError: LocalizedError, Sendable {
  case sessionChanged
  case cursorLoop
  case duplicateDelivery(String)
  case collectionChanged

  var errorDescription: String? {
    switch self {
    case .sessionChanged:
      "The account changed while productivity data was syncing."
    case .cursorLoop:
      "The server returned a repeated scheduled-message cursor."
    case .duplicateDelivery(let id):
      "The server returned scheduled message \(id) more than once."
    case .collectionChanged:
      "Scheduled messages kept changing while the complete list was loading."
    }
  }
}

nonisolated struct CloudProductivityDrainReport: Sendable {
  var foldersChanged = false
  var schedulesChanged = false
  var terminalErrors: [CloudProductivityTerminalError] = []
  var errors: [String] = []

  mutating func merge(_ other: Self) {
    foldersChanged = foldersChanged || other.foldersChanged
    schedulesChanged = schedulesChanged || other.schedulesChanged
    var existing = Set(terminalErrors.map(\.id))
    for failure in other.terminalErrors where existing.insert(failure.id).inserted {
      terminalErrors.append(failure)
    }
    errors.append(contentsOf: other.errors)
  }
}

/// Owns the account-scoped productivity network lane. It serializes paging and mutation drains,
/// and every response is checked against the exact account/token/store generation before commit.
actor CloudProductivitySyncCoordinator {
  private var context: AccountOperationContext?
  private var drainTask: (id: UUID, task: Task<CloudProductivityDrainReport, Never>)?
  private var activeOperations = 0
  private var quiescenceWaiters: [CheckedContinuation<Void, Never>] = []
  /// Actor methods are reentrant at each await. A later bind/cancel must win even if an older
  /// bind was already waiting for in-flight work to quiesce.
  private var bindingEpoch: UInt64 = 0

  func bind(_ context: AccountOperationContext) async {
    if let current = self.context,
      current.accountId == context.accountId,
      current.deviceId == context.deviceId,
      current.token == context.token,
      current.generation == context.generation,
      current.storeIdentity == context.storeIdentity
    {
      return
    }
    bindingEpoch &+= 1
    let epoch = bindingEpoch
    await quiesce()
    guard bindingEpoch == epoch else { return }
    self.context = context
  }

  func cancelAndWait() async {
    bindingEpoch &+= 1
    await quiesce()
  }

  private func quiesce() async {
    let draining = drainTask
    context = nil
    draining?.task.cancel()
    _ = await draining?.task.value
    if let draining, drainTask?.id == draining.id {
      drainTask = nil
    }
    if activeOperations > 0 {
      await withCheckedContinuation { continuation in
        quiescenceWaiters.append(continuation)
      }
    }
  }

  func isBound(to candidate: AccountOperationContext) -> Bool {
    guard let context else { return false }
    return context.accountId == candidate.accountId
      && context.deviceId == candidate.deviceId
      && context.token == candidate.token
      && context.generation == candidate.generation
      && context.storeIdentity == candidate.storeIdentity
  }

  func refreshFolders(api: CloudAPI) async throws -> CloudChatFolderSnapshot {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    let snapshot = try await api.chatFolders(token: operation.token)
    try ensureCurrent(operation)
    try await operation.store.saveChatFolderSnapshot(snapshot, accountId: operation.accountId)
    try ensureCurrent(operation)
    let effective = try await operation.store.effectiveChatFolderSnapshot(
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
    return effective
  }

  @discardableResult
  func refreshScheduledDeliveries(api: CloudAPI) async throws -> Bool {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    let snapshot = try await completeScheduledSnapshot(api: api, context: operation)
    try ensureCurrent(operation)
    let accepted = try await operation.store.replaceScheduledDeliveries(
      snapshot.deliveries,
      collectionRevision: snapshot.collectionRevision,
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
    if !accepted { LocalFirstMetrics.productivityRevisionRejected() }
    return accepted
  }

  func stageChatFolderMutation(
    _ intent: CloudFolderMutationIntent
  ) async throws -> CloudChatFolderSnapshot {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    try ensureCurrent(operation)
    let snapshot = try await operation.store.stageChatFolderMutation(
      intent,
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
    return snapshot
  }

  func stageScheduledCreate(
    _ request: CloudScheduledCreateRequest,
    draftOperationId: String?
  ) async throws -> CloudScheduledDelivery {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    try ensureCurrent(operation)
    let delivery = try await operation.store.stageScheduledCreate(
      request,
      accountId: operation.accountId,
      draftOperationId: draftOperationId
    )
    try ensureCurrent(operation)
    return delivery
  }

  func discardUnattemptedScheduledCreate(
    scheduleId: String
  ) async throws -> [CloudScheduledDelivery]? {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    try ensureCurrent(operation)
    let discarded = try await operation.store.discardUnattemptedScheduledCreate(
      scheduleId: scheduleId,
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
    guard discarded else { return nil }
    let effective = try await operation.store.scheduledDeliveries(
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
    return effective
  }

  func stageScheduledDeliveryMutation(
    _ intent: CloudScheduledMutationIntent
  ) async throws -> [CloudScheduledDelivery] {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    try ensureCurrent(operation)
    let deliveries = try await operation.store.stageScheduledDeliveryMutation(
      intent,
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
    return deliveries
  }

  func acknowledgeTerminalError(_ failure: CloudProductivityTerminalError) async throws {
    let operation = try requireContext()
    beginOperation()
    defer { endOperation() }
    try ensureCurrent(operation)
    try await operation.store.acknowledgeProductivityTerminalError(
      failure,
      accountId: operation.accountId
    )
    try ensureCurrent(operation)
  }

  func drain(api: CloudAPI) async -> CloudProductivityDrainReport {
    if let drainTask { return await drainTask.task.value }
    let id = UUID()
    let task = Task { [weak self] in
      guard let self else { return CloudProductivityDrainReport() }
      return await self.runDrain(api: api)
    }
    drainTask = (id, task)
    let report = await task.value
    if drainTask?.id == id {
      drainTask = nil
    }
    return report
  }

  private func runDrain(api: CloudAPI) async -> CloudProductivityDrainReport {
    guard let operation = context else { return CloudProductivityDrainReport() }
    var report = CloudProductivityDrainReport()
    do {
      if let age = try await operation.store.oldestProductivityMutationAge(
        accountId: operation.accountId
      ) {
        try ensureCurrent(operation)
        LocalFirstMetrics.productivityPendingQueueAge(age)
      }
      report.terminalErrors = try await operation.store
        .unacknowledgedProductivityTerminalErrors(accountId: operation.accountId)
      try ensureCurrent(operation)

      // Scheduled cancellations are the most time-sensitive productivity mutation. Drain
      // them before folder work, and isolate transient failures by schedule so an unrelated
      // cancellation is never held behind a bad network response for another schedule.
      let scheduled = try await drainScheduledMutations(api: api, operation: operation)
      report.merge(scheduled.report)
      if scheduled.restartRequired || scheduled.stopAll { return report }

      let folders = try await drainFolderMutations(api: api, operation: operation)
      report.merge(folders.report)
      if folders.restartRequired || folders.stopAll { return report }

      // Preparation can discover terminal local conflicts without issuing a request. Query
      // the durable errors again so this pass can publish them immediately.
      let terminal = try await operation.store.unacknowledgedProductivityTerminalErrors(
        accountId: operation.accountId
      )
      try ensureCurrent(operation)
      let final = CloudProductivityDrainReport(terminalErrors: terminal)
      report.merge(final)
    } catch is CancellationError {
      return report
    } catch CloudProductivityRefreshError.sessionChanged {
      return report
    } catch {
      report.errors.append(error.localizedDescription)
    }
    return report
  }

  private struct MutationDrainResult {
    var report = CloudProductivityDrainReport()
    var restartRequired = false
    var stopAll = false
  }

  private func drainScheduledMutations(
    api: CloudAPI,
    operation: AccountOperationContext
  ) async throws -> MutationDrainResult {
    var result = MutationDrainResult()
    var processed = 0
    while processed < 100 {
      let mutations = try await operation.store.pendingScheduledDeliveryMutationsReady(
        accountId: operation.accountId,
        limit: 1
      )
      try ensureCurrent(operation)
      guard !mutations.isEmpty else { break }
      for pending in mutations.prefix(100 - processed) {
        processed += 1
        try Task.checkCancellation()
        try ensureCurrent(operation)
        guard
          let prepared = try await operation.store.prepareScheduledDeliveryMutation(
            localOperationId: pending.localOperationId,
            accountId: operation.accountId
          ), prepared.request != nil, let requestData = prepared.requestData
        else {
          try ensureCurrent(operation)
          result.report.schedulesChanged = true
          if let message = try await operation.store.terminalScheduledDeliveryMutationError(
            localOperationId: pending.localOperationId,
            accountId: operation.accountId
          ) {
            result.report.terminalErrors.append(
              CloudProductivityTerminalError(
                source: .scheduledMutation,
                localOperationId: pending.localOperationId,
                message: message
              )
            )
          }
          try ensureCurrent(operation)
          continue
        }
        try ensureCurrent(operation)
        do {
          let response: CloudScheduledMutationResponse
          switch prepared.intent.operation {
          case .cancel:
            response = try await api.cancelScheduledDelivery(
              id: prepared.intent.scheduleId,
              persistedBody: requestData,
              token: operation.token
            )
          case .reschedule:
            response = try await api.updateScheduledDelivery(
              id: prepared.intent.scheduleId,
              persistedBody: requestData,
              token: operation.token
            )
          }
          try ensureCurrent(operation)
          try await operation.store.acknowledgeScheduledDeliveryMutation(
            localOperationId: prepared.localOperationId,
            operation: prepared.intent.operation,
            response: response,
            accountId: operation.accountId
          )
          try ensureCurrent(operation)
          result.report.schedulesChanged = true
        } catch {
          try ensureCurrent(operation)
          let code = (error as? CloudAPIError)?.code
          if code == "schedule_revision_conflict" {
            let latest = try await completeScheduledSnapshot(api: api, context: operation)
            try ensureCurrent(operation)
            _ = try await operation.store.replaceScheduledDeliveries(
              latest.deliveries,
              collectionRevision: latest.collectionRevision,
              accountId: operation.accountId
            )
            try ensureCurrent(operation)
            try await operation.store.rebaseScheduledDeliveryMutationAfterConflict(
              localOperationId: prepared.localOperationId,
              accountId: operation.accountId
            )
            try ensureCurrent(operation)
            result.report.schedulesChanged = true
            result.restartRequired = true
            return result
          }
          if code == "schedule_not_found", prepared.intent.operation == .cancel {
            try await operation.store.acknowledgeMissingScheduledDeliveryCancellation(
              localOperationId: prepared.localOperationId,
              scheduleId: prepared.intent.scheduleId,
              accountId: operation.accountId
            )
            try ensureCurrent(operation)
            result.report.schedulesChanged = true
            continue
          }
          let disposition = cloudOperationFailureDisposition(
            error,
            serverAdvertisesFeature: true
          )
          switch disposition {
          case .transient(let retryAfter):
            try await operation.store.deferScheduledDeliveryMutation(
              localOperationId: prepared.localOperationId,
              accountId: operation.accountId,
              after: retryAfter ?? Self.retryDelay(prepared.retryCount + 1),
              error: error.localizedDescription
            )
            try ensureCurrent(operation)
          case .authenticationRequired:
            try await operation.store.deferScheduledDeliveryMutation(
              localOperationId: prepared.localOperationId,
              accountId: operation.accountId,
              after: 30,
              error: "Sign in required"
            )
            try ensureCurrent(operation)
            result.stopAll = true
            return result
          case .unsupportedServer:
            try await operation.store.deferScheduledDeliveryMutation(
              localOperationId: prepared.localOperationId,
              accountId: operation.accountId,
              after: 300,
              error: error.localizedDescription
            )
            try ensureCurrent(operation)
          case .permanent:
            try await operation.store.deferScheduledDeliveryMutation(
              localOperationId: prepared.localOperationId,
              accountId: operation.accountId,
              after: 0,
              error: error.localizedDescription,
              terminal: true
            )
            try ensureCurrent(operation)
            result.report.terminalErrors.append(
              CloudProductivityTerminalError(
                source: .scheduledMutation,
                localOperationId: prepared.localOperationId,
                message: error.localizedDescription
              )
            )
            result.report.schedulesChanged = true
          }
        }
      }
    }
    return result
  }

  private func drainFolderMutations(
    api: CloudAPI,
    operation: AccountOperationContext
  ) async throws -> MutationDrainResult {
    var result = MutationDrainResult()
    var processed = 0
    while processed < 100 {
      let mutations = try await operation.store.pendingChatFolderMutationsReady(
        accountId: operation.accountId
      )
      try ensureCurrent(operation)
      guard let pending = mutations.first else { break }
      processed += 1
      try Task.checkCancellation()
      try ensureCurrent(operation)
      guard
        let prepared = try await operation.store.prepareChatFolderMutation(
          localOperationId: pending.localOperationId,
          accountId: operation.accountId
        ), prepared.request != nil, let requestData = prepared.requestData
      else {
        try ensureCurrent(operation)
        result.report.foldersChanged = true
        let message = try await operation.store.terminalChatFolderMutationError(
          localOperationId: pending.localOperationId,
          accountId: operation.accountId
        )
        try ensureCurrent(operation)
        if let message {
          result.report.terminalErrors.append(
            CloudProductivityTerminalError(
              source: .chatFolder,
              localOperationId: pending.localOperationId,
              message: message
            )
          )
        }
        continue
      }
      try ensureCurrent(operation)
      do {
        let snapshot: CloudChatFolderSnapshot
        switch prepared.intent.operation {
        case .create:
          snapshot = try await api.createChatFolder(
            persistedBody: requestData, token: operation.token
          )
        case .update:
          snapshot = try await api.updateChatFolder(
            id: prepared.intent.folderId,
            persistedBody: requestData,
            token: operation.token
          )
        case .delete:
          snapshot = try await api.deleteChatFolder(
            id: prepared.intent.folderId,
            persistedBody: requestData,
            token: operation.token
          )
        case .move:
          snapshot = try await api.moveChatFolder(
            id: prepared.intent.folderId,
            persistedBody: requestData,
            token: operation.token
          )
        }
        try ensureCurrent(operation)
        try await operation.store.acknowledgeChatFolderMutation(
          localOperationId: prepared.localOperationId,
          snapshot: snapshot,
          accountId: operation.accountId
        )
        try ensureCurrent(operation)
        result.report.foldersChanged = true
      } catch {
        try ensureCurrent(operation)
        if let apiError = error as? CloudAPIError,
          apiError.code == "folder_revision_conflict"
        {
          let latest = try await api.chatFolders(token: operation.token)
          try ensureCurrent(operation)
          try await operation.store.saveChatFolderSnapshot(
            latest,
            accountId: operation.accountId
          )
          try ensureCurrent(operation)
          try await operation.store.rebaseChatFolderMutationAfterConflict(
            localOperationId: prepared.localOperationId,
            accountId: operation.accountId
          )
          try ensureCurrent(operation)
          result.report.foldersChanged = true
          result.restartRequired = true
          return result
        }
        let disposition = cloudOperationFailureDisposition(
          error,
          serverAdvertisesFeature: true
        )
        switch disposition {
        case .transient(let retryAfter):
          try await operation.store.deferChatFolderMutation(
            localOperationId: prepared.localOperationId,
            accountId: operation.accountId,
            after: retryAfter ?? Self.retryDelay(prepared.retryCount + 1),
            error: error.localizedDescription
          )
          try ensureCurrent(operation)
          result.stopAll = true
          return result
        case .authenticationRequired:
          try await operation.store.deferChatFolderMutation(
            localOperationId: prepared.localOperationId,
            accountId: operation.accountId,
            after: 30,
            error: "Sign in required"
          )
          try ensureCurrent(operation)
          result.stopAll = true
          return result
        case .unsupportedServer:
          try await operation.store.deferChatFolderMutation(
            localOperationId: prepared.localOperationId,
            accountId: operation.accountId,
            after: 300,
            error: error.localizedDescription
          )
          try ensureCurrent(operation)
          result.stopAll = true
          return result
        case .permanent:
          try await operation.store.deferChatFolderMutation(
            localOperationId: prepared.localOperationId,
            accountId: operation.accountId,
            after: 0,
            error: error.localizedDescription,
            terminal: true
          )
          try ensureCurrent(operation)
          result.report.terminalErrors.append(
            CloudProductivityTerminalError(
              source: .chatFolder,
              localOperationId: prepared.localOperationId,
              message: error.localizedDescription
            )
          )
          result.report.foldersChanged = true
        }
      }
    }
    return result
  }

  private func completeScheduledSnapshot(
    api: CloudAPI,
    context operation: AccountOperationContext
  ) async throws -> CloudScheduledListResponse {
    let maximumRevisionRestarts = 3
    for attempt in 0...maximumRevisionRestarts {
      try Task.checkCancellation()
      try ensureCurrent(operation)
      var deliveries: [CloudScheduledDelivery] = []
      var deliveryIds: Set<String> = []
      var seenCursors: Set<String> = []
      var cursor: String?
      var collectionRevision: Int64?
      var collectionChanged = false
      repeat {
        let page: CloudScheduledListResponse
        do {
          page = try await api.scheduledDeliveries(
            cursor: cursor,
            token: operation.token
          )
        } catch {
          LocalFirstMetrics.productivityRefreshIncomplete("page_failure")
          throw error
        }
        try ensureCurrent(operation)
        if let expected = collectionRevision, expected != page.collectionRevision {
          collectionChanged = true
          break
        }
        collectionRevision = page.collectionRevision
        for delivery in page.deliveries {
          guard deliveryIds.insert(delivery.scheduleId).inserted else {
            LocalFirstMetrics.productivityRefreshIncomplete("duplicate_delivery")
            throw CloudProductivityRefreshError.duplicateDelivery(delivery.scheduleId)
          }
          deliveries.append(delivery)
        }
        if let next = page.nextCursor {
          guard seenCursors.insert(next).inserted else {
            LocalFirstMetrics.productivityRefreshIncomplete("cursor_loop")
            throw CloudProductivityRefreshError.cursorLoop
          }
        }
        cursor = page.nextCursor
      } while cursor != nil
      if collectionChanged {
        LocalFirstMetrics.productivityRevisionRestart(attempt + 1)
        if attempt == maximumRevisionRestarts {
          LocalFirstMetrics.productivityRefreshIncomplete("revision_drift")
          throw CloudProductivityRefreshError.collectionChanged
        }
        continue
      }
      return CloudScheduledListResponse(
        collectionRevision: collectionRevision ?? 0,
        deliveries: deliveries,
        nextCursor: nil
      )
    }
    throw CloudProductivityRefreshError.collectionChanged
  }

  private func requireContext() throws -> AccountOperationContext {
    guard let context else { throw CloudProductivityRefreshError.sessionChanged }
    return context
  }

  private func ensureCurrent(_ candidate: AccountOperationContext) throws {
    guard let current = context,
      current.accountId == candidate.accountId,
      current.deviceId == candidate.deviceId,
      current.token == candidate.token,
      current.generation == candidate.generation,
      current.storeIdentity == candidate.storeIdentity
    else {
      LocalFirstMetrics.productivityStaleSessionResultDiscarded()
      throw CloudProductivityRefreshError.sessionChanged
    }
  }

  private func beginOperation() {
    activeOperations += 1
  }

  private func endOperation() {
    activeOperations -= 1
    guard activeOperations == 0 else { return }
    let waiters = quiescenceWaiters
    quiescenceWaiters.removeAll()
    waiters.forEach { $0.resume() }
  }

  private static func retryDelay(_ retryCount: Int) -> TimeInterval {
    min(300, max(2, pow(2, Double(min(retryCount, 8)))))
  }
}
