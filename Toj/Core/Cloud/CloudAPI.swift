import Foundation

struct CloudMessage: Codable, Identifiable, Equatable, Sendable {
    var id: String { "\(dialogId):\(msgId)" }
    let dialogId: String
    let msgId: Int64
    let senderAccountId: String
    let clientMsgId: String
    let kind: String
    let text: String
    let editVersion: Int
    let state: String
    let serverTs: String

    enum CodingKeys: String, CodingKey {
        case dialogId = "dialog_id"
        case msgId = "msg_id"
        case senderAccountId = "sender_account_id"
        case clientMsgId = "client_msg_id"
        case kind
        case text
        case editVersion = "edit_version"
        case state
        case serverTs = "server_ts"
    }
}

struct CloudUpdate: Codable, Sendable {
    let pts: Int64
    let ptsCount: Int64
    let type: String
    let dialogId: String?
    let dialogTitle: String?
    let message: CloudMessage?
    let readerAccountId: String?
    let maxReadMsgId: Int64?

    enum CodingKeys: String, CodingKey {
        case pts
        case ptsCount
        case type
        case dialogId = "dialog_id"
        case dialogTitle = "dialog_title"
        case message
        case readerAccountId = "reader_account_id"
        case maxReadMsgId = "max_read_msg_id"
    }
}

struct CloudSession: Codable, Equatable, Sendable {
    let accountId: String
    let deviceId: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case accountId
        case deviceId
        case token
    }
}

struct StoredCloudSession: Codable, Equatable, Sendable {
    let session: CloudSession
    let phone: String
    let displayName: String
}

struct AuthStartResponse: Codable, Sendable {
    let code: String?
}

struct ContactLookupResponse: Codable, Sendable {
    let accountId: String?
    let displayName: String?
    let found: Bool?
}

struct DirectDialogResponse: Codable, Sendable {
    let dialogId: String
    let created: Bool
}

struct SendMessageResponse: Codable, Sendable {
    let dialogId: String
    let clientMsgId: String
    let msgId: Int64
    let senderPts: Int64
    let duplicate: Bool
    let serverTs: String?
    let text: String?
}

struct SyncStateResponse: Codable, Sendable {
    let pts: Int64
}

struct DifferenceResponse: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let kind: String
    let state: State
    let updates: [CloudUpdate]?
    let hasMore: Bool?
}

struct BootstrapStartResponse: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let token: String
    let state: State
    let expiresAt: String
    let dialogCount: Int

    enum CodingKeys: String, CodingKey {
        case token
        case state
        case expiresAt
        case dialogCount
    }
}

struct BootstrapDialogMember: Codable, Equatable, Sendable {
    let accountId: String
    let role: String
    let lastReadMsgId: Int64

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case role
        case lastReadMsgId = "last_read_msg_id"
    }
}

struct BootstrapDialog: Codable, Equatable, Sendable {
    let dialogId: String
    let type: String
    let title: String?
    let lastMsgId: Int64
    let updatedAt: String
    let members: [BootstrapDialogMember]
    let messages: [CloudMessage]

    enum CodingKeys: String, CodingKey {
        case dialogId = "dialog_id"
        case type
        case title
        case lastMsgId = "last_msg_id"
        case updatedAt = "updated_at"
        case members
        case messages
    }
}

struct BootstrapDialogsPage: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let token: String
    let state: State
    let dialogs: [BootstrapDialog]
    let nextCursor: String?
    let hasMore: Bool
}

struct HistoryPageResponse: Codable, Sendable {
    let dialogId: String
    let messages: [CloudMessage]
    let nextBeforeMsgId: Int64?
    let hasMore: Bool

    enum CodingKeys: String, CodingKey {
        case dialogId
        case messages
        case nextBeforeMsgId
        case hasMore
    }
}

struct ReadResponse: Codable, Sendable {
    let dialogId: String
    let maxReadMsgId: Int64
}

struct CloudAPIError: Error, LocalizedError {
    let status: Int
    let message: String

    var errorDescription: String? {
        message
    }
}

struct CloudAPI: Sendable {
    let config: CloudConfig
    var session: URLSession = .shared

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        return encoder
    }()

    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        return decoder
    }()

    func startAuth(phone: String) async throws -> AuthStartResponse {
        try await post("v1/auth/start", body: ["phone": phone], token: nil)
    }

    func checkAuth(phone: String, code: String, displayName: String, deviceName: String) async throws -> CloudSession {
        try await post(
            "v1/auth/check",
            body: [
                "phone": phone,
                "code": code,
                "platform": "ios",
                "deviceName": deviceName,
                "displayName": displayName
            ],
            token: nil
        )
    }

    func lookupContact(phone: String, token: String) async throws -> ContactLookupResponse {
        try await post("v1/contacts/lookup", body: ["phone": phone], token: token)
    }

    func createDirectDialog(peerAccountId: String, token: String) async throws -> DirectDialogResponse {
        try await post("v1/dialogs/direct", body: ["peerAccountId": peerAccountId], token: token)
    }

    func getState(token: String) async throws -> SyncStateResponse {
        try await get("v1/sync/state", token: token)
    }

    func getDifference(sincePts: Int64, token: String) async throws -> DifferenceResponse {
        try await post("v1/sync/difference", body: ["sincePts": sincePts], token: token)
    }

    func startBootstrap(token: String) async throws -> BootstrapStartResponse {
        try await post("v1/bootstrap/start", body: EmptyBody(), token: token)
    }

    func getBootstrapDialogs(
        bootstrapToken: String,
        cursor: String?,
        limit: Int = 20,
        previewMessages: Int = 25,
        token: String
    ) async throws -> BootstrapDialogsPage {
        try await post(
            "v1/bootstrap/dialogs",
            body: BootstrapDialogsRequest(
                token: bootstrapToken,
                cursor: cursor,
                limit: limit,
                previewMessages: previewMessages
            ),
            token: token
        )
    }

    func sendMessage(dialogId: String, clientMsgId: String, body: String, token: String) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: ["dialogId": dialogId, "clientMsgId": clientMsgId, "kind": "text", "body": body],
            token: token
        )
    }

    func getHistory(dialogId: String, beforeMsgId: Int64?, limit: Int = 50, token: String) async throws -> HistoryPageResponse {
        try await post(
            "v1/history",
            body: HistoryRequest(dialogId: dialogId, beforeMsgId: beforeMsgId, limit: limit),
            token: token
        )
    }

    func markRead(dialogId: String, maxReadMsgId: Int64, token: String) async throws -> ReadResponse {
        try await post(
            "v1/read",
            body: ReadRequest(dialogId: dialogId, maxReadMsgId: maxReadMsgId),
            token: token
        )
    }

    private func get<Response: Decodable>(_ path: String, token: String?) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "GET"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func post<Body: Encodable, Response: Decodable>(_ path: String, body: Body, token: String?) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func run<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError(status: -1, message: "Invalid server response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? decoder.decode(ServerError.self, from: data).error)
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            throw CloudAPIError(status: http.statusCode, message: message)
        }
        return try decoder.decode(Response.self, from: data)
    }
}

private struct ServerError: Codable {
    let error: String
}

private struct EmptyBody: Encodable {}

private struct BootstrapDialogsRequest: Encodable {
    let token: String
    let cursor: String?
    let limit: Int
    let previewMessages: Int
}

private struct HistoryRequest: Encodable {
    let dialogId: String
    let beforeMsgId: Int64?
    let limit: Int
}

private struct ReadRequest: Encodable {
    let dialogId: String
    let maxReadMsgId: Int64
}
