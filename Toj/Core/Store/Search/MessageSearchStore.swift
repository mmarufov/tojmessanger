import Foundation
import GRDB

/// One search hit, carrying enough to render a row without a second query.
///
/// `text` comes from `messages`, never from the index: the FTS table is contentless and, more
/// importantly, displayed text must be exactly what the bubble shows. Highlight ranges are computed
/// from it by `SearchTextNormalizer.highlightRanges(of:in:)`.
nonisolated struct MessageSearchHit: Equatable, Sendable, Identifiable {
    /// Which tier returned this row. The store never re-sorts across tiers, so this is also the
    /// ordering key: every `.exact` hit precedes every `.folded` one.
    enum Tier: Int, Sendable, Comparable {
        case exact = 0
        case folded = 1
        static func < (lhs: Tier, rhs: Tier) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    let docId: Int64
    let clientMsgId: String
    let localId: String
    let dialogId: String
    let msgId: Int64?
    let senderAccountId: String
    let kind: String
    let text: String
    /// Presentation metadata captured in the same query so rows never expose internal identifiers
    /// or need an N+1 lookup to resolve a chat/file label.
    let dialogTitle: String
    let fileNames: String
    let sortTimestamp: Int64
    let hasMedia: Bool
    let tier: Tier

    var id: Int64 { docId }
}

/// A page of hits plus the cursor needed to ask for the next one.
nonisolated struct MessageSearchPage: Equatable, Sendable {
    let hits: [MessageSearchHit]
    let cursor: MessageSearchCursor?
    var isEmpty: Bool { hits.isEmpty }
}

/// Keyset position, never an offset.
///
/// Carries the tier because the two tiers are paginated in sequence: the folded tier only starts
/// once the exact tier is exhausted, so resuming needs to know which one it was in.
nonisolated struct MessageSearchCursor: Equatable, Sendable {
    let tier: MessageSearchHit.Tier
    let sortTimestamp: Int64
    let docId: Int64
}

/// What the caller is searching for. Mirrors the scope pills.
nonisolated enum MessageSearchScope: Equatable, Sendable {
    case messages
    case media
    case files
    case links

    /// `nil` means no `kind` restriction.
    var kinds: [String]? {
        switch self {
        case .messages: nil
        case .media: ["photo", "video"]
        case .files: ["file", "voice"]
        case .links: nil
        }
    }

    var requiresLink: Bool { self == .links }
}

nonisolated struct MessageSearchRequest: Equatable, Sendable {
    var query: String
    var scope: MessageSearchScope = .messages
    /// Restricts to one conversation, for in-chat search.
    var dialogId: String?
    var limit: Int = 40
    var cursor: MessageSearchCursor?
    /// False once the user submits, where whole-word matching is less surprising than prefix.
    var prefixMatching: Bool = true
}

extension CloudLocalStore {
    /// Runs the two-tier search.
    ///
    /// The exact tier is exhausted before the folded tier begins, which is what makes "exact ranks
    /// above folded" a property of the query plan rather than a scoring heuristic. Within a tier,
    /// ordering is recency — people search for something they remember, and that is what Telegram
    /// and WhatsApp do.
    ///
    /// An empty query is legitimate: with a scope it becomes a browse, which is what makes the
    /// Media, Files and Links tabs useful before the user types anything.
    func searchMessages(_ request: MessageSearchRequest) throws -> MessageSearchPage {
        let plan = SearchPatternBuilder.prepare(request.query, prefixMatching: request.prefixMatching)
        if plan == nil, !request.query.trimmingCharacters(in: .whitespaces).isEmpty {
            // The query had characters but no tokens — punctuation or an emoji the tokenizer treats
            // as a separator. Browsing here would be worse than nothing: the user typed something.
            return MessageSearchPage(hits: [], cursor: nil)
        }

        return try dbQueue.read { db in
            guard try db.tableExists("message_search") else {
                // Index absent or being rebuilt. Empty results, never an error: search degrades,
                // the app does not.
                return MessageSearchPage(hits: [], cursor: nil)
            }

            var hits: [MessageSearchHit] = []
            let startTier = request.cursor?.tier ?? .exact

            for tier in [MessageSearchHit.Tier.exact, .folded] where tier >= startTier {
                guard hits.count < request.limit else { break }
                let cursor = tier == startTier ? request.cursor : nil
                hits += try Self.fetchTier(
                    db, request: request, plan: plan, tier: tier,
                    cursor: cursor, limit: request.limit - hits.count,
                    excluding: Set(hits.map(\.docId))
                )
            }

            let cursor = hits.count == request.limit
                ? hits.last.map {
                    MessageSearchCursor(tier: $0.tier, sortTimestamp: $0.sortTimestamp, docId: $0.docId)
                }
                : nil
            return MessageSearchPage(hits: hits, cursor: cursor)
        }
    }

    /// Every matching message id in one dialog, for in-chat prev/next.
    ///
    /// Returns ids rather than hits because the caller navigates rather than renders, and capping
    /// keeps a pathological query from materializing a whole conversation.
    func searchInDialog(
        _ dialogId: String, query: String, limit: Int = 500
    ) throws -> [Int64] {
        let page = try searchMessages(MessageSearchRequest(
            query: query, dialogId: dialogId, limit: limit, prefixMatching: false
        ))
        return page.hits.compactMap(\.msgId)
    }

    // MARK: - Internals

    /// Dialogs whose content may surface. Revoked and closed conversations are excluded here as
    /// well as being purged from the index, because the filter takes effect the instant
    /// `access_state` flips while the index removal waits on the drain — and "instant" is the
    /// requirement when someone has just been removed from a group.
    static let visibleAccessStates = ["active", "pending"]

    fileprivate static func fetchTier(
        _ db: Database, request: MessageSearchRequest, plan: PreparedSearchQuery?,
        tier: MessageSearchHit.Tier, cursor: MessageSearchCursor?, limit: Int,
        excluding: Set<Int64>
    ) throws -> [MessageSearchHit] {
        var conditions: [String] = []
        var arguments: [DatabaseValueConvertible?] = []

        let source: String
        if let plan {
            source = """
                message_search f
                JOIN message_search_docs d ON d.doc_id = f.rowid
                """
            conditions.append("message_search MATCH ?")
            var expression = tier == .exact ? plan.exactExpression : plan.foldedOnlyExpression
            if let dialogId = request.dialogId {
                expression = SearchPatternBuilder.scoped(expression, toDialog: dialogId)
            }
            arguments.append(expression)
        } else {
            // Browse mode: no query, so the index is irrelevant and the docs table alone orders by
            // recency. This is what makes the Media, Files and Links tabs useful before typing.
            guard tier == .exact else { return [] }
            source = "message_search_docs d"
        }

        conditions.append("""
            dl.access_state IN (\(visibleAccessStates.map { _ in "?" }.joined(separator: ", ")))
            """)
        arguments.append(contentsOf: visibleAccessStates)

        // The index is eventually consistent; results are not allowed to be. A message deleted,
        // edited, or re-attached since the last drain still has its old row in `message_search`,
        // and showing it would surface text the user believes is gone. Joining `messages` lets the
        // authoritative row veto the indexed one, and excluding anything still queued covers the
        // rest — a pending entry is precisely the statement "this doc no longer describes reality".
        conditions.append("m.state = 'visible'")
        conditions.append("m.kind <> 'service'")
        conditions.append("""
            NOT EXISTS (
                SELECT 1 FROM search_index_queue q WHERE q.client_msg_id = d.client_msg_id
            )
            """)

        if let dialogId = request.dialogId {
            conditions.append("d.dialog_id = ?")
            arguments.append(dialogId)
        }
        if let kinds = request.scope.kinds {
            conditions.append("d.kind IN (\(kinds.map { _ in "?" }.joined(separator: ", ")))")
            arguments.append(contentsOf: kinds)
        }
        if request.scope.requiresLink {
            conditions.append("d.link_count > 0")
        }
        if let cursor {
            // Row-value keyset. Never OFFSET: a page boundary must not shift when a message
            // arrives mid-scroll.
            conditions.append("(d.sort_ts, d.doc_id) < (?, ?)")
            arguments.append(cursor.sortTimestamp)
            arguments.append(cursor.docId)
        }
        if !excluding.isEmpty {
            let placeholders = excluding.map { _ in "?" }.joined(separator: ", ")
            conditions.append("d.doc_id NOT IN (\(placeholders))")
            arguments.append(contentsOf: excluding.map { $0 })
        }

        arguments.append(limit)

        let rows = try Row.fetchAll(db, sql: """
            SELECT d.doc_id, d.client_msg_id, d.local_id, d.dialog_id, d.msg_id,
                   d.sender_account_id, d.kind, d.sort_ts, d.has_media, m.text,
                   COALESCE(NULLIF(dl.title, ''), 'Chat') AS dialog_title,
                   COALESCE((
                       SELECT group_concat(mm.file_name, ' · ')
                         FROM message_media mm
                        WHERE mm.local_id = m.local_id
                          AND mm.file_name IS NOT NULL AND mm.file_name <> ''
                   ), '') AS file_names
              FROM \(source)
              JOIN messages m ON m.client_msg_id = d.client_msg_id
              JOIN dialogs dl ON dl.dialog_id = d.dialog_id
             WHERE \(conditions.joined(separator: " AND "))
             ORDER BY d.sort_ts DESC, d.doc_id DESC
             LIMIT ?
            """, arguments: StatementArguments(arguments))

        return rows.map { row in
            MessageSearchHit(
                docId: row["doc_id"], clientMsgId: row["client_msg_id"], localId: row["local_id"],
                dialogId: row["dialog_id"], msgId: row["msg_id"],
                senderAccountId: row["sender_account_id"], kind: row["kind"], text: row["text"],
                dialogTitle: row["dialog_title"], fileNames: row["file_names"],
                sortTimestamp: row["sort_ts"], hasMedia: (row["has_media"] as Int? ?? 0) != 0,
                tier: tier
            )
        }
    }
}
