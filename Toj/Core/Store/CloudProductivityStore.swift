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
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: """
                DELETE FROM cloud_scheduled_deliveries
                WHERE account_id = ?
                  AND schedule_id NOT IN (
                    SELECT schedule_id FROM pending_scheduled_delivery_creates
                    WHERE account_id = ?
                  )
                """,
                arguments: [accountId, accountId]
            )
            for delivery in deliveries {
                try Self.upsertScheduledDelivery(db, delivery: delivery, accountId: accountId)
            }
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
                       next_retry_at, last_error
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
                    draftOperationId: row["draft_operation_id"],
                    retryCount: row["retry_count"],
                    nextRetryAt: row["next_retry_at"],
                    lastError: row["last_error"]
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
                       next_retry_at, last_error
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
                draftOperationId: row["draft_operation_id"],
                retryCount: row["retry_count"],
                nextRetryAt: row["next_retry_at"],
                lastError: row["last_error"]
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
                  next_retry_at = ?, last_error = ?, terminal = ?
                WHERE schedule_id = ? AND account_id = ?
                """,
                arguments: [next, String(error.prefix(240)), terminal, scheduleId, accountId]
            )
        }
    }

    func discardPendingScheduledCreate(scheduleId: String, accountId: String) throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM pending_scheduled_delivery_creates WHERE schedule_id = ? AND account_id = ?",
                arguments: [scheduleId, accountId]
            )
            try db.execute(
                sql: "DELETE FROM cloud_scheduled_deliveries WHERE schedule_id = ? AND account_id = ? AND revision = 0",
                arguments: [scheduleId, accountId]
            )
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
        accountId: String
    ) throws {
        try dbQueue.write { db in
            try Self.upsertScheduledDelivery(db, delivery: delivery, accountId: accountId)
        }
    }

    func scheduledDeliveries(
        accountId: String,
        dialogId: String? = nil
    ) throws -> [CloudScheduledDelivery] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                SELECT payload_json FROM cloud_scheduled_deliveries
                WHERE account_id = ? AND (? IS NULL OR dialog_id = ?)
                ORDER BY deliver_at, schedule_id
                """,
                arguments: [accountId, dialogId, dialogId]
            )
            return rows.compactMap { row in
                (row["payload_json"] as String?)
                    .flatMap { $0.data(using: .utf8) }
                    .flatMap { try? JSONDecoder().decode(CloudScheduledDelivery.self, from: $0) }
            }
        }
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
}
