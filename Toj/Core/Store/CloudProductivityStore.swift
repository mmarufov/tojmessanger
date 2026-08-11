import Foundation
import GRDB

extension CloudLocalStore {
    func saveChatFolderSnapshot(
        _ snapshot: CloudChatFolderSnapshot,
        accountId: String
    ) throws {
        let json = String(
            data: try JSONEncoder().encode(snapshot),
            encoding: .utf8
        )!
        try dbQueue.write { db in
            let current = try Int64.fetchOne(
                db,
                sql: "SELECT collection_revision FROM cloud_chat_folder_state WHERE account_id = ?",
                arguments: [accountId]
            ) ?? -1
            guard snapshot.collectionRevision >= current else { return }
            try db.execute(
                sql: """
                INSERT INTO cloud_chat_folder_state(
                  account_id, collection_revision, snapshot_json, updated_at
                ) VALUES (?, ?, ?, datetime('now'))
                ON CONFLICT(account_id) DO UPDATE SET
                  collection_revision = excluded.collection_revision,
                  snapshot_json = excluded.snapshot_json,
                  updated_at = excluded.updated_at
                """,
                arguments: [accountId, snapshot.collectionRevision, json]
            )
        }
    }

    func chatFolderSnapshot(accountId: String) throws -> CloudChatFolderSnapshot? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: "SELECT snapshot_json FROM cloud_chat_folder_state WHERE account_id = ?",
                arguments: [accountId]
            )
            .flatMap { $0.data(using: .utf8) }
            .flatMap { try? JSONDecoder().decode(CloudChatFolderSnapshot.self, from: $0) }
        }
    }

    func replaceScheduledDeliveries(
        _ deliveries: [CloudScheduledDelivery],
        collectionRevision: Int64,
        accountId: String
    ) throws -> Bool {
        try dbQueue.write { db in
            let currentRevision = try Int64.fetchOne(
                db,
                sql: "SELECT collection_revision FROM cloud_scheduled_delivery_state WHERE account_id = ?",
                arguments: [accountId]
            ) ?? -1
            guard collectionRevision >= currentRevision else { return false }
            try db.execute(
                sql: """
                DELETE FROM cloud_scheduled_deliveries
                WHERE account_id = ?
                  AND schedule_id NOT IN (
                    SELECT schedule_id FROM pending_scheduled_delivery_creates
                    WHERE account_id = ?
                    UNION
                    SELECT schedule_id FROM pending_scheduled_delivery_mutations
                    WHERE account_id = ? AND terminal = 0
                  )
                """,
                arguments: [accountId, accountId, accountId]
            )
            for delivery in deliveries {
                try Self.upsertScheduledDelivery(db, delivery: delivery, accountId: accountId)
            }
            try Self.advanceScheduledCollectionRevision(
                db,
                accountId: accountId,
                collectionRevision: collectionRevision
            )
            return true
        }
    }

    func stageScheduledCreate(
        _ request: CloudScheduledCreateRequest,
        accountId: String,
        draftOperationId: String?
    ) throws -> CloudScheduledDelivery {
        let now = ISO8601DateFormatter().string(from: Date())
        let requestJSON = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
        let pending = CloudScheduledDelivery(
            scheduleId: request.scheduleId,
            dialogId: request.dialogId,
            deliverAt: request.deliverAt,
            state: "local_pending",
            silent: request.silent,
            reminder: request.reminder,
            revision: 0,
            attempts: 0,
            lastErrorCode: nil,
            deliveredFirstMsgId: nil,
            deliveredLastMsgId: nil,
            items: request.items,
            createdAt: now,
            updatedAt: now,
            completedAt: nil
        )
        try dbQueue.write { db in
            try db.execute(
                sql: """
                INSERT INTO pending_scheduled_delivery_creates(
                  schedule_id, account_id, dialog_id, request_json, draft_operation_id,
                  retry_count, next_retry_at, last_error, terminal, created_at
                ) VALUES (?, ?, ?, ?, ?, 0, NULL, NULL, 0, ?)
                ON CONFLICT(schedule_id) DO NOTHING
                """,
                arguments: [
                    request.scheduleId, accountId, request.dialogId, requestJSON,
                    draftOperationId, now,
                ]
            )
            try Self.upsertScheduledDelivery(db, delivery: pending, accountId: accountId)
        }
        return pending
    }

    func pendingScheduledCreatesReady(accountId: String) throws -> [PendingScheduledCreate] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT account_id, request_json, draft_operation_id, retry_count,
                       next_retry_at, last_error, attempted_at
                FROM pending_scheduled_delivery_creates
                WHERE account_id = ? AND terminal = 0
                  AND (next_retry_at IS NULL OR datetime(next_retry_at) <= datetime('now'))
                ORDER BY created_at, schedule_id
                """,
                arguments: [accountId]
            )
            return rows.compactMap { row in
                guard let json: String = row["request_json"],
                      let data = json.data(using: .utf8),
                      let request = try? JSONDecoder().decode(CloudScheduledCreateRequest.self, from: data)
                else { return nil }
                return PendingScheduledCreate(
                    accountId: row["account_id"],
                    request: request,
                    requestData: data,
                    draftOperationId: row["draft_operation_id"],
                    retryCount: row["retry_count"],
                    nextRetryAt: row["next_retry_at"],
                    lastError: row["last_error"],
                    attemptedAt: row["attempted_at"]
                )
            }
        }
    }

    func pendingScheduledCreate(
        scheduleId: String,
        accountId: String
    ) throws -> PendingScheduledCreate? {
        try dbQueue.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT account_id, request_json, draft_operation_id, retry_count,
                       next_retry_at, last_error, attempted_at
                FROM pending_scheduled_delivery_creates
                WHERE schedule_id = ? AND account_id = ?
                """,
                arguments: [scheduleId, accountId]
            ), let json: String = row["request_json"],
               let data = json.data(using: .utf8),
               let request = try? JSONDecoder().decode(CloudScheduledCreateRequest.self, from: data)
            else { return nil }
            return PendingScheduledCreate(
                accountId: row["account_id"],
                request: request,
                requestData: data,
                draftOperationId: row["draft_operation_id"],
                retryCount: row["retry_count"],
                nextRetryAt: row["next_retry_at"],
                lastError: row["last_error"],
                attemptedAt: row["attempted_at"]
            )
        }
    }

    func markScheduledCreateAttempted(scheduleId: String, accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_scheduled_delivery_creates
                SET attempted_at = COALESCE(attempted_at, ?)
                WHERE schedule_id = ? AND account_id = ?
                """,
                arguments: [ISO8601DateFormatter().string(from: Date()), scheduleId, accountId]
            )
        }
    }

    func acknowledgeScheduledCreate(
        _ response: CloudScheduledMutationResponse,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM pending_scheduled_delivery_creates WHERE schedule_id = ? AND account_id = ?",
                arguments: [response.scheduledDelivery.scheduleId, accountId]
            )
            try Self.upsertScheduledDelivery(db, delivery: response.scheduledDelivery, accountId: accountId)
            try Self.advanceScheduledCollectionRevision(
                db,
                accountId: accountId,
                collectionRevision: response.collectionRevision
            )
        }
    }

    func deferScheduledCreate(
        scheduleId: String,
        accountId: String,
        after delay: TimeInterval,
        error: String,
        terminal: Bool = false
    ) throws {
        try dbQueue.write { db in
            let next = terminal ? nil : ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(max(1, delay))
            )
            try db.execute(
                sql: """
                UPDATE pending_scheduled_delivery_creates SET
                  retry_count = retry_count + 1,
                  next_retry_at = ?, last_error = ?, terminal = ?, error_acknowledged = 0
                WHERE schedule_id = ? AND account_id = ?
                """,
                arguments: [next, String(error.prefix(240)), terminal, scheduleId, accountId]
            )
            if terminal,
               let current = try Self.canonicalScheduledDelivery(
                db,
                scheduleId: scheduleId,
                accountId: accountId
               ), current.revision == 0 {
                let failed = CloudScheduledDelivery(
                    scheduleId: current.scheduleId,
                    dialogId: current.dialogId,
                    deliverAt: current.deliverAt,
                    state: "local_error",
                    silent: current.silent,
                    reminder: current.reminder,
                    revision: current.revision,
                    attempts: current.attempts,
                    lastErrorCode: "local_create_failed",
                    deliveredFirstMsgId: current.deliveredFirstMsgId,
                    deliveredLastMsgId: current.deliveredLastMsgId,
                    items: current.items,
                    createdAt: current.createdAt,
                    updatedAt: ISO8601DateFormatter().string(from: Date()),
                    completedAt: current.completedAt
                )
                try Self.upsertScheduledDelivery(db, delivery: failed, accountId: accountId)
            }
        }
    }

    func discardUnattemptedScheduledCreate(scheduleId: String, accountId: String) throws -> Bool {
        try dbQueue.write { db in
            guard try String.fetchOne(
                db,
                sql: """
                SELECT schedule_id FROM pending_scheduled_delivery_creates
                WHERE schedule_id = ? AND account_id = ? AND attempted_at IS NULL
                """,
                arguments: [scheduleId, accountId]
            ) != nil else { return false }
            try db.execute(
                sql: """
                DELETE FROM pending_scheduled_delivery_creates
                WHERE schedule_id = ? AND account_id = ? AND attempted_at IS NULL
                """,
                arguments: [scheduleId, accountId]
            )
            try db.execute(
                sql: "DELETE FROM cloud_scheduled_deliveries WHERE schedule_id = ? AND account_id = ? AND revision = 0",
                arguments: [scheduleId, accountId]
            )
            return true
        }
    }

    func nextScheduledCreateRetryDelay(accountId: String) throws -> TimeInterval? {
        try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(COALESCE(next_retry_at, datetime('now')))
                FROM pending_scheduled_delivery_creates
                WHERE account_id = ? AND terminal = 0
                """,
                arguments: [accountId]
            ) else { return nil }
            let formatter = ISO8601DateFormatter()
            return formatter.date(from: value).map { max(0, $0.timeIntervalSinceNow) } ?? 0
        }
    }

    func upsertScheduledDelivery(
        _ delivery: CloudScheduledDelivery,
        collectionRevision: Int64? = nil,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try Self.upsertScheduledDelivery(db, delivery: delivery, accountId: accountId)
            if let collectionRevision {
                try Self.advanceScheduledCollectionRevision(
                    db,
                    accountId: accountId,
                    collectionRevision: collectionRevision
                )
            }
        }
    }

    func scheduledDeliveries(
        accountId: String,
        dialogId: String? = nil
    ) throws -> [CloudScheduledDelivery] {
        try dbQueue.read { db in
            try Self.effectiveScheduledDeliveries(db, accountId: accountId, dialogId: dialogId)
        }
    }

    func scheduledCollectionRevision(accountId: String) throws -> Int64 {
        try dbQueue.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT collection_revision FROM cloud_scheduled_delivery_state WHERE account_id = ?",
                arguments: [accountId]
            ) ?? 0
        }
    }

    func nextProductivityMutationRetryDelay(accountId: String) throws -> TimeInterval? {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                WITH folder_head AS (
                  SELECT mutation.next_retry_at
                  FROM pending_chat_folder_mutations AS mutation
                  WHERE mutation.account_id = ? AND mutation.terminal = 0
                  ORDER BY mutation.local_order
                  LIMIT 1
                ), scheduled_heads AS (
                  SELECT mutation.next_retry_at
                  FROM pending_scheduled_delivery_mutations AS mutation
                  WHERE mutation.account_id = ? AND mutation.terminal = 0
                    AND mutation.local_order = (
                      SELECT MIN(candidate.local_order)
                      FROM pending_scheduled_delivery_mutations AS candidate
                      WHERE candidate.account_id = mutation.account_id
                        AND candidate.schedule_id = mutation.schedule_id
                        AND candidate.terminal = 0
                        AND (
                          candidate.operation = 'cancel'
                          OR NOT EXISTS (
                            SELECT 1 FROM pending_scheduled_delivery_mutations AS cancellation
                            WHERE cancellation.account_id = candidate.account_id
                              AND cancellation.schedule_id = candidate.schedule_id
                              AND cancellation.terminal = 0
                              AND cancellation.operation = 'cancel'
                          )
                        )
                    )
                    AND NOT EXISTS (
                      SELECT 1 FROM pending_scheduled_delivery_creates AS pending_create
                      WHERE pending_create.account_id = mutation.account_id
                        AND pending_create.schedule_id = mutation.schedule_id
                        AND pending_create.terminal = 0
                    )
                )
                SELECT next_retry_at FROM folder_head
                UNION ALL
                SELECT next_retry_at FROM scheduled_heads
                """,
                arguments: [accountId, accountId]
            )
            guard !rows.isEmpty else { return nil }
            let formatter = ISO8601DateFormatter()
            var minimum = TimeInterval.greatestFiniteMagnitude
            for row in rows {
                guard let value: String = row["next_retry_at"] else { return 0 }
                guard let date = formatter.date(from: value) else { return 0 }
                minimum = min(minimum, max(0, date.timeIntervalSinceNow))
            }
            return minimum
        }
    }

    func oldestProductivityMutationAge(accountId: String) throws -> TimeInterval? {
        try dbQueue.read { db in
            guard let value = try String.fetchOne(
                db,
                sql: """
                SELECT MIN(created_at) FROM (
                  SELECT created_at FROM pending_chat_folder_mutations
                  WHERE account_id = ? AND terminal = 0
                  UNION ALL
                  SELECT created_at FROM pending_scheduled_delivery_creates
                  WHERE account_id = ? AND terminal = 0
                  UNION ALL
                  SELECT created_at FROM pending_scheduled_delivery_mutations
                  WHERE account_id = ? AND terminal = 0
                )
                """,
                arguments: [accountId, accountId, accountId]
            ), let createdAt = ISO8601DateFormatter().date(from: value) else { return nil }
            return max(0, Date().timeIntervalSince(createdAt))
        }
    }

    func unacknowledgedProductivityTerminalErrors(
        accountId: String
    ) throws -> [CloudProductivityTerminalError] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT 'chatFolder' AS source, local_operation_id AS operation_id,
                       last_error, created_at
                FROM pending_chat_folder_mutations
                WHERE account_id = ? AND terminal = 1 AND error_acknowledged = 0
                UNION ALL
                SELECT 'scheduledCreate' AS source, schedule_id AS operation_id,
                       last_error, created_at
                FROM pending_scheduled_delivery_creates
                WHERE account_id = ? AND terminal = 1 AND error_acknowledged = 0
                UNION ALL
                SELECT 'scheduledMutation' AS source, local_operation_id AS operation_id,
                       last_error, created_at
                FROM pending_scheduled_delivery_mutations
                WHERE account_id = ? AND terminal = 1 AND error_acknowledged = 0
                ORDER BY created_at, operation_id
                """,
                arguments: [accountId, accountId, accountId]
            )
            return rows.compactMap { row in
                guard let rawSource: String = row["source"],
                      let source = CloudProductivityTerminalErrorSource(rawValue: rawSource),
                      let operationId: String = row["operation_id"],
                      let message: String = row["last_error"] else { return nil }
                return CloudProductivityTerminalError(
                    source: source,
                    localOperationId: operationId,
                    message: message
                )
            }
        }
    }

    func acknowledgeProductivityTerminalError(
        _ failure: CloudProductivityTerminalError,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            switch failure.source {
            case .chatFolder:
                try db.execute(
                    sql: """
                    DELETE FROM pending_chat_folder_mutations
                    WHERE account_id = ? AND local_operation_id = ? AND terminal = 1
                    """,
                    arguments: [accountId, failure.localOperationId]
                )
            case .scheduledMutation:
                try db.execute(
                    sql: """
                    DELETE FROM pending_scheduled_delivery_mutations
                    WHERE account_id = ? AND local_operation_id = ? AND terminal = 1
                    """,
                    arguments: [accountId, failure.localOperationId]
                )
            case .scheduledCreate:
                // Keep the rejected create until the user removes its visible local-error row.
                // Its terminal marker proves that a later cancellation is a safe local no-op.
                try db.execute(
                    sql: """
                    UPDATE pending_scheduled_delivery_creates SET error_acknowledged = 1
                    WHERE account_id = ? AND schedule_id = ? AND terminal = 1
                    """,
                    arguments: [accountId, failure.localOperationId]
                )
            }
        }
    }

    // MARK: - Durable chat-folder mutations

    func stageChatFolderMutation(
        _ intent: CloudFolderMutationIntent,
        accountId: String
    ) throws -> CloudChatFolderSnapshot {
        try dbQueue.write { db in
            let operationId = UUID().uuidString.lowercased()
            let now = ISO8601DateFormatter().string(from: Date())
            let intentJSON = String(data: try JSONEncoder().encode(intent), encoding: .utf8)!
            let localOrder = try Self.nextProductivityMutationOrder(db)
            try db.execute(
                sql: """
                INSERT INTO pending_chat_folder_mutations(
                  local_operation_id, account_id, folder_id, operation, intent_json,
                  local_order, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    operationId, accountId, intent.folderId, intent.operation.rawValue,
                    intentJSON, localOrder, now,
                ]
            )
            return try Self.effectiveChatFolderSnapshot(db, accountId: accountId)
        }
    }

    func effectiveChatFolderSnapshot(accountId: String) throws -> CloudChatFolderSnapshot {
        try dbQueue.read { db in
            try Self.effectiveChatFolderSnapshot(db, accountId: accountId)
        }
    }

    func pendingChatFolderMutationsReady(accountId: String) throws -> [PendingChatFolderMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_chat_folder_mutations AS mutation
                WHERE mutation.account_id = ? AND mutation.terminal = 0
                  AND mutation.local_order = (
                    SELECT MIN(head.local_order)
                    FROM pending_chat_folder_mutations AS head
                    WHERE head.account_id = mutation.account_id AND head.terminal = 0
                  )
                  AND (
                    mutation.next_retry_at IS NULL
                    OR datetime(mutation.next_retry_at) <= datetime('now')
                  )
                LIMIT 1
                """,
                arguments: [accountId]
            ).compactMap(Self.pendingChatFolderMutation(from:))
        }
    }

    func prepareChatFolderMutation(
        localOperationId: String,
        accountId: String
    ) throws -> PendingChatFolderMutation? {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pending_chat_folder_mutations
                WHERE local_operation_id = ? AND account_id = ? AND terminal = 0
                """,
                arguments: [localOperationId, accountId]
            ), var pending = Self.pendingChatFolderMutation(from: row) else { return nil }
            if pending.request != nil { return pending }

            let canonical = try Self.canonicalChatFolderSnapshot(db, accountId: accountId)
            let mutationId = UUID().uuidString.lowercased()
            let request: CloudFolderMutationRequest
            switch pending.intent.operation {
            case .create:
                guard let folder = pending.intent.folder else { return nil }
                request = CloudFolderMutationRequest(
                    clientMutationId: mutationId,
                    folderId: folder.folderId,
                    title: folder.title,
                    icon: folder.icon,
                    includeDirect: folder.includeDirect,
                    includeGroups: folder.includeGroups,
                    includeSaved: folder.includeSaved,
                    excludeRead: folder.excludeRead,
                    excludeMuted: folder.excludeMuted,
                    excludeArchived: folder.excludeArchived,
                    rules: folder.rules
                )
            case .update:
                guard let folder = pending.intent.folder,
                      canonical.folders.contains(where: { $0.folderId == folder.folderId }) else {
                    try Self.markProductivityMutationTerminal(
                        db,
                        table: "pending_chat_folder_mutations",
                        localOperationId: localOperationId,
                        error: "Folder was deleted on another device"
                    )
                    return nil
                }
                request = CloudFolderMutationRequest(
                    clientMutationId: mutationId,
                    title: folder.title,
                    icon: folder.icon,
                    includeDirect: folder.includeDirect,
                    includeGroups: folder.includeGroups,
                    includeSaved: folder.includeSaved,
                    excludeRead: folder.excludeRead,
                    excludeMuted: folder.excludeMuted,
                    excludeArchived: folder.excludeArchived,
                    rules: folder.rules,
                    expectedRevision: canonical.collectionRevision
                )
            case .delete:
                guard canonical.folders.contains(where: { $0.folderId == pending.intent.folderId }) else {
                    try db.execute(
                        sql: "DELETE FROM pending_chat_folder_mutations WHERE local_operation_id = ?",
                        arguments: [localOperationId]
                    )
                    return nil
                }
                request = CloudFolderMutationRequest(
                    clientMutationId: mutationId,
                    expectedRevision: canonical.collectionRevision
                )
            case .move:
                guard canonical.folders.contains(where: { $0.folderId == pending.intent.folderId }) else {
                    try db.execute(
                        sql: "DELETE FROM pending_chat_folder_mutations WHERE local_operation_id = ?",
                        arguments: [localOperationId]
                    )
                    return nil
                }
                let anchors = Self.rebasedFolderAnchors(
                    intent: pending.intent,
                    canonicalFolders: canonical.folders
                )
                guard anchors.before != nil || anchors.after != nil else {
                    try db.execute(
                        sql: "DELETE FROM pending_chat_folder_mutations WHERE local_operation_id = ?",
                        arguments: [localOperationId]
                    )
                    return nil
                }
                request = CloudFolderMutationRequest(
                    clientMutationId: mutationId,
                    expectedRevision: canonical.collectionRevision,
                    beforeFolderId: anchors.before,
                    afterFolderId: anchors.after
                )
            }
            let requestJSON = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
            let attemptedAt = ISO8601DateFormatter().string(from: Date())
            try db.execute(
                sql: """
                UPDATE pending_chat_folder_mutations SET
                  client_mutation_id = ?, request_json = ?, attempted_at = ?,
                  next_retry_at = NULL, last_error = NULL
                WHERE local_operation_id = ? AND account_id = ?
                """,
                arguments: [mutationId, requestJSON, attemptedAt, localOperationId, accountId]
            )
            pending = PendingChatFolderMutation(
                localOperationId: pending.localOperationId,
                accountId: pending.accountId,
                intent: pending.intent,
                clientMutationId: mutationId,
                request: request,
                requestData: Data(requestJSON.utf8),
                retryCount: pending.retryCount,
                attemptedAt: attemptedAt,
                lastError: nil,
                terminal: false,
                localOrder: pending.localOrder
            )
            return pending
        }
    }

    func acknowledgeChatFolderMutation(
        localOperationId: String,
        snapshot: CloudChatFolderSnapshot,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try Self.saveCanonicalChatFolderSnapshot(db, snapshot: snapshot, accountId: accountId)
            try db.execute(
                sql: "DELETE FROM pending_chat_folder_mutations WHERE local_operation_id = ? AND account_id = ?",
                arguments: [localOperationId, accountId]
            )
        }
    }

    func rebaseChatFolderMutationAfterConflict(
        localOperationId: String,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_chat_folder_mutations SET
                  client_mutation_id = NULL, request_json = NULL, attempted_at = NULL,
                  next_retry_at = NULL, last_error = NULL
                WHERE local_operation_id = ? AND account_id = ? AND terminal = 0
                """,
                arguments: [localOperationId, accountId]
            )
        }
    }

    func deferChatFolderMutation(
        localOperationId: String,
        accountId: String,
        after delay: TimeInterval,
        error: String,
        terminal: Bool = false
    ) throws {
        try deferProductivityMutation(
            table: "pending_chat_folder_mutations",
            localOperationId: localOperationId,
            accountId: accountId,
            after: delay,
            error: error,
            terminal: terminal
        )
    }

    func terminalChatFolderMutationError(
        localOperationId: String,
        accountId: String
    ) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT last_error FROM pending_chat_folder_mutations
                WHERE local_operation_id = ? AND account_id = ? AND terminal = 1
                """,
                arguments: [localOperationId, accountId]
            )
        }
    }

    // MARK: - Durable scheduled-delivery mutations

    func stageScheduledDeliveryMutation(
        _ intent: CloudScheduledMutationIntent,
        accountId: String
    ) throws -> [CloudScheduledDelivery] {
        try dbQueue.write { db in
            if intent.operation == .cancel {
                // A cancellation supersedes reschedules that have definitely not reached the wire.
                try db.execute(
                    sql: """
                    DELETE FROM pending_scheduled_delivery_mutations
                    WHERE account_id = ? AND schedule_id = ? AND operation = 'reschedule'
                      AND attempted_at IS NULL
                    """,
                    arguments: [accountId, intent.scheduleId]
                )
            }
            let operationId = UUID().uuidString.lowercased()
            let now = ISO8601DateFormatter().string(from: Date())
            let intentJSON = String(data: try JSONEncoder().encode(intent), encoding: .utf8)!
            let localOrder = try Self.nextProductivityMutationOrder(db)
            try db.execute(
                sql: """
                INSERT INTO pending_scheduled_delivery_mutations(
                  local_operation_id, account_id, schedule_id, operation, intent_json,
                  local_order, created_at
                ) VALUES (?, ?, ?, ?, ?, ?, ?)
                """,
                arguments: [
                    operationId, accountId, intent.scheduleId, intent.operation.rawValue,
                    intentJSON, localOrder, now,
                ]
            )
            return try Self.effectiveScheduledDeliveries(db, accountId: accountId, dialogId: nil)
        }
    }

    func pendingScheduledDeliveryMutationsReady(
        accountId: String,
        limit: Int = 100
    ) throws -> [PendingScheduledDeliveryMutation] {
        try dbQueue.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT * FROM pending_scheduled_delivery_mutations AS mutation
                WHERE mutation.account_id = ? AND mutation.terminal = 0
                  AND mutation.local_order = (
                    SELECT MIN(candidate.local_order)
                    FROM pending_scheduled_delivery_mutations AS candidate
                    WHERE candidate.account_id = mutation.account_id
                      AND candidate.schedule_id = mutation.schedule_id
                      AND candidate.terminal = 0
                      AND (
                        candidate.operation = 'cancel'
                        OR NOT EXISTS (
                          SELECT 1 FROM pending_scheduled_delivery_mutations AS cancellation
                          WHERE cancellation.account_id = candidate.account_id
                            AND cancellation.schedule_id = candidate.schedule_id
                            AND cancellation.terminal = 0
                            AND cancellation.operation = 'cancel'
                        )
                      )
                  )
                  AND (
                    mutation.next_retry_at IS NULL
                    OR datetime(mutation.next_retry_at) <= datetime('now')
                  )
                  AND NOT EXISTS (
                    SELECT 1 FROM pending_scheduled_delivery_creates pending_create
                    WHERE pending_create.account_id = mutation.account_id
                      AND pending_create.schedule_id = mutation.schedule_id
                      AND pending_create.terminal = 0
                  )
                ORDER BY CASE mutation.operation WHEN 'cancel' THEN 0 ELSE 1 END,
                         mutation.local_order
                LIMIT ?
                """,
                arguments: [accountId, max(1, min(limit, 100))]
            ).compactMap(Self.pendingScheduledDeliveryMutation(from:))
        }
    }

    func prepareScheduledDeliveryMutation(
        localOperationId: String,
        accountId: String
    ) throws -> PendingScheduledDeliveryMutation? {
        try dbQueue.write { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                SELECT * FROM pending_scheduled_delivery_mutations
                WHERE local_operation_id = ? AND account_id = ? AND terminal = 0
                """,
                arguments: [localOperationId, accountId]
            ), var pending = Self.pendingScheduledDeliveryMutation(from: row) else { return nil }
            if pending.intent.operation == .reschedule {
                let cancellationExists = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM pending_scheduled_delivery_mutations
                      WHERE account_id = ? AND schedule_id = ? AND terminal = 0
                        AND operation = 'cancel'
                    )
                    """,
                    arguments: [accountId, pending.intent.scheduleId]
                ) ?? false
                // Whether or not exact request bytes already exist, a newly staged cancellation
                // owns the next wire slot. Retain uncertain bytes until that cancel is acknowledged.
                if cancellationExists { return nil }
            }
            if pending.request != nil { return pending }
            guard let delivery = try Self.canonicalScheduledDelivery(
                db,
                scheduleId: pending.intent.scheduleId,
                accountId: accountId
            ) else {
                // A local create must be acknowledged before a mutation can bind to a server revision.
                let createExists = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM pending_scheduled_delivery_creates
                      WHERE schedule_id = ? AND account_id = ? AND terminal = 0
                    )
                    """,
                    arguments: [pending.intent.scheduleId, accountId]
                ) ?? false
                if !createExists {
                    try Self.markProductivityMutationTerminal(
                        db,
                        table: "pending_scheduled_delivery_mutations",
                        localOperationId: localOperationId,
                        error: "Scheduled message is no longer available"
                    )
                }
                return nil
            }
            if delivery.revision == 0 {
                let createIsTerminal = try Bool.fetchOne(
                    db,
                    sql: """
                    SELECT EXISTS(
                      SELECT 1 FROM pending_scheduled_delivery_creates
                      WHERE schedule_id = ? AND account_id = ? AND terminal = 1
                    )
                    """,
                    arguments: [pending.intent.scheduleId, accountId]
                ) ?? false
                guard createIsTerminal else { return nil }
                if pending.intent.operation == .cancel {
                    // A definitive create rejection proves there is no server schedule to orphan.
                    // The queued cancellation is therefore an authoritative local no-op.
                    try db.execute(
                        sql: "DELETE FROM pending_scheduled_delivery_mutations WHERE account_id = ? AND schedule_id = ?",
                        arguments: [accountId, pending.intent.scheduleId]
                    )
                    try db.execute(
                        sql: "DELETE FROM pending_scheduled_delivery_creates WHERE account_id = ? AND schedule_id = ?",
                        arguments: [accountId, pending.intent.scheduleId]
                    )
                    try db.execute(
                        sql: "DELETE FROM cloud_scheduled_deliveries WHERE account_id = ? AND schedule_id = ? AND revision = 0",
                        arguments: [accountId, pending.intent.scheduleId]
                    )
                } else {
                    try Self.markProductivityMutationTerminal(
                        db,
                        table: "pending_scheduled_delivery_mutations",
                        localOperationId: localOperationId,
                        error: "The original scheduled message was not accepted by the server"
                    )
                }
                return nil
            }
            if delivery.state == "canceled", pending.intent.operation == .cancel {
                try db.execute(
                    sql: "DELETE FROM pending_scheduled_delivery_mutations WHERE local_operation_id = ?",
                    arguments: [localOperationId]
                )
                return nil
            }
            guard delivery.state == "scheduled" else {
                try Self.markProductivityMutationTerminal(
                    db,
                    table: "pending_scheduled_delivery_mutations",
                    localOperationId: localOperationId,
                    error: "Scheduled message is already \(delivery.state)"
                )
                return nil
            }
            let mutationId = UUID().uuidString.lowercased()
            let request = CloudScheduledMutationRequest(
                clientMutationId: mutationId,
                expectedRevision: delivery.revision,
                deliverAt: pending.intent.deliverAt
            )
            let requestJSON = String(data: try JSONEncoder().encode(request), encoding: .utf8)!
            let attemptedAt = ISO8601DateFormatter().string(from: Date())
            try db.execute(
                sql: """
                UPDATE pending_scheduled_delivery_mutations SET
                  client_mutation_id = ?, request_json = ?, attempted_at = ?,
                  next_retry_at = NULL, last_error = NULL
                WHERE local_operation_id = ? AND account_id = ?
                """,
                arguments: [mutationId, requestJSON, attemptedAt, localOperationId, accountId]
            )
            pending = PendingScheduledDeliveryMutation(
                localOperationId: pending.localOperationId,
                accountId: pending.accountId,
                intent: pending.intent,
                clientMutationId: mutationId,
                request: request,
                requestData: Data(requestJSON.utf8),
                retryCount: pending.retryCount,
                attemptedAt: attemptedAt,
                lastError: nil,
                terminal: false,
                localOrder: pending.localOrder
            )
            return pending
        }
    }

    func acknowledgeScheduledDeliveryMutation(
        localOperationId: String,
        operation: CloudScheduledMutationOperation,
        response: CloudScheduledMutationResponse,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try Self.upsertScheduledDelivery(
                db,
                delivery: response.scheduledDelivery,
                accountId: accountId
            )
            try Self.advanceScheduledCollectionRevision(
                db,
                accountId: accountId,
                collectionRevision: response.collectionRevision
            )
            if operation == .cancel {
                try db.execute(
                    sql: "DELETE FROM pending_scheduled_delivery_mutations WHERE account_id = ? AND schedule_id = ?",
                    arguments: [accountId, response.scheduledDelivery.scheduleId]
                )
            } else {
                try db.execute(
                    sql: "DELETE FROM pending_scheduled_delivery_mutations WHERE local_operation_id = ? AND account_id = ?",
                    arguments: [localOperationId, accountId]
                )
            }
        }
    }

    func acknowledgeMissingScheduledDeliveryCancellation(
        localOperationId: String,
        scheduleId: String,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM pending_scheduled_delivery_mutations
                WHERE account_id = ? AND schedule_id = ?
                """,
                arguments: [accountId, scheduleId]
            )
            try db.execute(
                sql: """
                DELETE FROM cloud_scheduled_deliveries
                WHERE account_id = ? AND schedule_id = ?
                """,
                arguments: [accountId, scheduleId]
            )
        }
    }

    func rebaseScheduledDeliveryMutationAfterConflict(
        localOperationId: String,
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                UPDATE pending_scheduled_delivery_mutations SET
                  client_mutation_id = NULL, request_json = NULL, attempted_at = NULL,
                  next_retry_at = NULL, last_error = NULL
                WHERE local_operation_id = ? AND account_id = ? AND terminal = 0
                """,
                arguments: [localOperationId, accountId]
            )
        }
    }

    func deferScheduledDeliveryMutation(
        localOperationId: String,
        accountId: String,
        after delay: TimeInterval,
        error: String,
        terminal: Bool = false
    ) throws {
        try deferProductivityMutation(
            table: "pending_scheduled_delivery_mutations",
            localOperationId: localOperationId,
            accountId: accountId,
            after: delay,
            error: error,
            terminal: terminal
        )
    }

    func terminalScheduledDeliveryMutationError(
        localOperationId: String,
        accountId: String
    ) throws -> String? {
        try dbQueue.read { db in
            try String.fetchOne(
                db,
                sql: """
                SELECT last_error FROM pending_scheduled_delivery_mutations
                WHERE local_operation_id = ? AND account_id = ? AND terminal = 1
                """,
                arguments: [localOperationId, accountId]
            )
        }
    }

    private func deferProductivityMutation(
        table: String,
        localOperationId: String,
        accountId: String,
        after delay: TimeInterval,
        error: String,
        terminal: Bool
    ) throws {
        precondition([
            "pending_chat_folder_mutations", "pending_scheduled_delivery_mutations",
        ].contains(table))
        try dbQueue.write { db in
            let next = terminal ? nil : ISO8601DateFormatter().string(
                from: Date().addingTimeInterval(max(1, delay))
            )
            try db.execute(
                sql: """
                UPDATE \(table) SET retry_count = retry_count + 1,
                  next_retry_at = ?, last_error = ?, terminal = ?, error_acknowledged = 0
                WHERE local_operation_id = ? AND account_id = ?
                """,
                arguments: [
                    next, String(error.prefix(240)), terminal,
                    localOperationId, accountId,
                ]
            )
        }
    }

    // MARK: - Storage helpers

    private static func canonicalChatFolderSnapshot(
        _ db: Database,
        accountId: String
    ) throws -> CloudChatFolderSnapshot {
        guard let json = try String.fetchOne(
            db,
            sql: "SELECT snapshot_json FROM cloud_chat_folder_state WHERE account_id = ?",
            arguments: [accountId]
        ), let data = json.data(using: .utf8),
              let snapshot = try? JSONDecoder().decode(CloudChatFolderSnapshot.self, from: data)
        else {
            return CloudChatFolderSnapshot(
                collectionRevision: 0,
                folders: [],
                clientMutationId: nil,
                pts: nil,
                duplicate: nil
            )
        }
        return snapshot
    }

    private static func saveCanonicalChatFolderSnapshot(
        _ db: Database,
        snapshot: CloudChatFolderSnapshot,
        accountId: String
    ) throws {
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT collection_revision FROM cloud_chat_folder_state WHERE account_id = ?",
            arguments: [accountId]
        ) ?? -1
        guard snapshot.collectionRevision >= current else { return }
        let json = String(data: try JSONEncoder().encode(snapshot), encoding: .utf8)!
        try db.execute(
            sql: """
            INSERT INTO cloud_chat_folder_state(
              account_id, collection_revision, snapshot_json, updated_at
            ) VALUES (?, ?, ?, datetime('now'))
            ON CONFLICT(account_id) DO UPDATE SET
              collection_revision = excluded.collection_revision,
              snapshot_json = excluded.snapshot_json,
              updated_at = excluded.updated_at
            """,
            arguments: [accountId, snapshot.collectionRevision, json]
        )
    }

    private static func effectiveChatFolderSnapshot(
        _ db: Database,
        accountId: String
    ) throws -> CloudChatFolderSnapshot {
        let canonical = try canonicalChatFolderSnapshot(db, accountId: accountId)
        var folders = canonical.folders.sorted { $0.position < $1.position }
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT intent_json FROM pending_chat_folder_mutations
            WHERE account_id = ? AND terminal = 0 ORDER BY local_order
            """,
            arguments: [accountId]
        )
        for row in rows {
            guard let json: String = row["intent_json"],
                  let data = json.data(using: .utf8),
                  let intent = try? JSONDecoder().decode(CloudFolderMutationIntent.self, from: data)
            else { continue }
            switch intent.operation {
            case .create:
                if let folder = intent.folder,
                   !folders.contains(where: { $0.folderId == folder.folderId }) {
                    folders.append(folder)
                }
            case .update:
                if let folder = intent.folder,
                   let index = folders.firstIndex(where: { $0.folderId == folder.folderId }) {
                    folders[index] = folder
                }
            case .delete:
                folders.removeAll { $0.folderId == intent.folderId }
            case .move:
                folders = applyFolderMove(intent: intent, to: folders)
            }
            folders = normalizedFolderPositions(folders)
        }
        return CloudChatFolderSnapshot(
            collectionRevision: canonical.collectionRevision,
            folders: folders,
            clientMutationId: canonical.clientMutationId,
            pts: canonical.pts,
            duplicate: canonical.duplicate
        )
    }

    private static func applyFolderMove(
        intent: CloudFolderMutationIntent,
        to folders: [CloudChatFolder]
    ) -> [CloudChatFolder] {
        guard let source = folders.first(where: { $0.folderId == intent.folderId }) else {
            return folders
        }
        var result = folders.filter { $0.folderId != intent.folderId }
        let anchors = rebasedFolderAnchors(intent: intent, canonicalFolders: result)
        if let before = anchors.before,
           let index = result.firstIndex(where: { $0.folderId == before }) {
            result.insert(source, at: index)
        } else if let after = anchors.after,
                  let index = result.firstIndex(where: { $0.folderId == after }) {
            result.insert(source, at: index + 1)
        } else {
            return folders
        }
        return result
    }

    private static func rebasedFolderAnchors(
        intent: CloudFolderMutationIntent,
        canonicalFolders: [CloudChatFolder]
    ) -> (before: String?, after: String?) {
        let surviving = Set(canonicalFolders.map(\.folderId)).subtracting([intent.folderId])
        if let before = intent.beforeFolderId, surviving.contains(before) {
            return (before, nil)
        }
        if let after = intent.afterFolderId, surviving.contains(after) {
            return (nil, after)
        }
        guard let desiredOrder = intent.desiredOrder,
              let targetIndex = desiredOrder.firstIndex(of: intent.folderId) else {
            return (nil, nil)
        }
        if targetIndex + 1 < desiredOrder.count {
            for id in desiredOrder[(targetIndex + 1)...] where surviving.contains(id) {
                return (id, nil)
            }
        }
        if targetIndex > 0 {
            for id in desiredOrder[..<targetIndex].reversed() where surviving.contains(id) {
                return (nil, id)
            }
        }
        return (nil, nil)
    }

    private static func normalizedFolderPositions(
        _ folders: [CloudChatFolder]
    ) -> [CloudChatFolder] {
        folders.enumerated().map { index, folder in
            CloudChatFolder(
                folderId: folder.folderId,
                title: folder.title,
                icon: folder.icon,
                position: index,
                includeDirect: folder.includeDirect,
                includeGroups: folder.includeGroups,
                includeSaved: folder.includeSaved,
                excludeRead: folder.excludeRead,
                excludeMuted: folder.excludeMuted,
                excludeArchived: folder.excludeArchived,
                revision: folder.revision,
                rules: folder.rules,
                createdAt: folder.createdAt,
                updatedAt: folder.updatedAt
            )
        }
    }

    private static func effectiveScheduledDeliveries(
        _ db: Database,
        accountId: String,
        dialogId: String?
    ) throws -> [CloudScheduledDelivery] {
        let rows = try Row.fetchAll(
            db,
            sql: """
            SELECT payload_json FROM cloud_scheduled_deliveries
            WHERE account_id = ? AND (? IS NULL OR dialog_id = ?)
            ORDER BY deliver_at, schedule_id
            """,
            arguments: [accountId, dialogId, dialogId]
        )
        var deliveries = rows.compactMap { row in
            (row["payload_json"] as String?)
                .flatMap { $0.data(using: .utf8) }
                .flatMap { try? JSONDecoder().decode(CloudScheduledDelivery.self, from: $0) }
        }
        let mutationRows = try Row.fetchAll(
            db,
            sql: """
            SELECT intent_json FROM pending_scheduled_delivery_mutations
            WHERE account_id = ? AND terminal = 0
            ORDER BY CASE operation WHEN 'cancel' THEN 1 ELSE 0 END, local_order
            """,
            arguments: [accountId]
        )
        for row in mutationRows {
            guard let json: String = row["intent_json"],
                  let data = json.data(using: .utf8),
                  let intent = try? JSONDecoder().decode(
                    CloudScheduledMutationIntent.self,
                    from: data
                  ),
                  let index = deliveries.firstIndex(where: {
                    $0.scheduleId == intent.scheduleId
                  }) else { continue }
            deliveries[index] = deliveries[index].applyingPendingMutation(intent)
        }
        return deliveries
    }

    private static func canonicalScheduledDelivery(
        _ db: Database,
        scheduleId: String,
        accountId: String
    ) throws -> CloudScheduledDelivery? {
        try String.fetchOne(
            db,
            sql: """
            SELECT payload_json FROM cloud_scheduled_deliveries
            WHERE schedule_id = ? AND account_id = ?
            """,
            arguments: [scheduleId, accountId]
        )
        .flatMap { $0.data(using: .utf8) }
        .flatMap { try? JSONDecoder().decode(CloudScheduledDelivery.self, from: $0) }
    }

    private static func pendingChatFolderMutation(from row: Row) -> PendingChatFolderMutation? {
        guard let intentJSON: String = row["intent_json"],
              let intentData = intentJSON.data(using: .utf8),
              let intent = try? JSONDecoder().decode(CloudFolderMutationIntent.self, from: intentData)
        else { return nil }
        let requestData = (row["request_json"] as String?).flatMap { $0.data(using: .utf8) }
        let request = requestData.flatMap {
            try? JSONDecoder().decode(CloudFolderMutationRequest.self, from: $0)
        }
        return PendingChatFolderMutation(
            localOperationId: row["local_operation_id"],
            accountId: row["account_id"],
            intent: intent,
            clientMutationId: row["client_mutation_id"],
            request: request,
            requestData: requestData,
            retryCount: row["retry_count"],
            attemptedAt: row["attempted_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0,
            localOrder: row["local_order"]
        )
    }

    private static func pendingScheduledDeliveryMutation(
        from row: Row
    ) -> PendingScheduledDeliveryMutation? {
        guard let intentJSON: String = row["intent_json"],
              let intentData = intentJSON.data(using: .utf8),
              let intent = try? JSONDecoder().decode(
                CloudScheduledMutationIntent.self,
                from: intentData
              ) else { return nil }
        let requestData = (row["request_json"] as String?).flatMap { $0.data(using: .utf8) }
        let request = requestData.flatMap {
            try? JSONDecoder().decode(CloudScheduledMutationRequest.self, from: $0)
        }
        return PendingScheduledDeliveryMutation(
            localOperationId: row["local_operation_id"],
            accountId: row["account_id"],
            intent: intent,
            clientMutationId: row["client_mutation_id"],
            request: request,
            requestData: requestData,
            retryCount: row["retry_count"],
            attemptedAt: row["attempted_at"],
            lastError: row["last_error"],
            terminal: (row["terminal"] as Int) != 0,
            localOrder: row["local_order"]
        )
    }

    private static func nextProductivityMutationOrder(_ db: Database) throws -> Int64 {
        let order = try Int64.fetchOne(
            db,
            sql: "SELECT next_order FROM local_mutation_sequence WHERE singleton = 1"
        ) ?? 1
        try db.execute(
            sql: """
            INSERT INTO local_mutation_sequence(singleton, next_order) VALUES (1, ?)
            ON CONFLICT(singleton) DO UPDATE SET next_order = excluded.next_order
            """,
            arguments: [order + 1]
        )
        return order
    }

    private static func markProductivityMutationTerminal(
        _ db: Database,
        table: String,
        localOperationId: String,
        error: String
    ) throws {
        precondition([
            "pending_chat_folder_mutations", "pending_scheduled_delivery_mutations",
        ].contains(table))
        try db.execute(
            sql: """
            UPDATE \(table) SET terminal = 1, last_error = ?, next_retry_at = NULL
            WHERE local_operation_id = ?
            """,
            arguments: [String(error.prefix(240)), localOperationId]
        )
    }

    private static func upsertScheduledDelivery(
        _ db: Database,
        delivery: CloudScheduledDelivery,
        accountId: String
    ) throws {
        let json = String(data: try JSONEncoder().encode(delivery), encoding: .utf8)!
        let current = try Int64.fetchOne(
            db,
            sql: "SELECT revision FROM cloud_scheduled_deliveries WHERE schedule_id = ?",
            arguments: [delivery.scheduleId]
        ) ?? -1
        guard delivery.revision >= current else { return }
        try db.execute(
            sql: """
            INSERT INTO cloud_scheduled_deliveries(
              schedule_id, account_id, dialog_id, state, deliver_at,
              revision, payload_json, updated_at
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(schedule_id) DO UPDATE SET
              state = excluded.state,
              deliver_at = excluded.deliver_at,
              revision = excluded.revision,
              payload_json = excluded.payload_json,
              updated_at = excluded.updated_at
            """,
            arguments: [
                delivery.scheduleId, accountId, delivery.dialogId, delivery.state,
                delivery.deliverAt, delivery.revision, json, delivery.updatedAt
            ]
        )
    }

    private static func advanceScheduledCollectionRevision(
        _ db: Database,
        accountId: String,
        collectionRevision: Int64
    ) throws {
        try db.execute(
            sql: """
            INSERT INTO cloud_scheduled_delivery_state(account_id, collection_revision, updated_at)
            VALUES (?, ?, datetime('now'))
            ON CONFLICT(account_id) DO UPDATE SET
              collection_revision = MAX(collection_revision, excluded.collection_revision),
              updated_at = CASE
                WHEN excluded.collection_revision >= collection_revision THEN excluded.updated_at
                ELSE updated_at
              END
            """,
            arguments: [accountId, collectionRevision]
        )
    }
}
