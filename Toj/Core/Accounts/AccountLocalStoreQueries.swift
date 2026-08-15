import GRDB

extension CloudLocalStore {
    func aggregateUnreadCount() async throws -> Int {
        try await dbQueue.read { db in
            try Int.fetchOne(
                db,
                sql: """
                    SELECT COALESCE(SUM(unread_count), 0)
                    FROM dialog_unread_summaries
                    WHERE unread_count > 0
                    """
            ) ?? 0
        }
    }
}
