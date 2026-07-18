import Foundation

nonisolated struct CloudReaction: Codable, Equatable, Sendable {
    let accountId: String
    let emoji: String

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case emoji
    }
}

nonisolated struct CloudMessage: Codable, Identifiable, Equatable, Sendable {
    nonisolated var id: String { "\(dialogId):\(msgId)" }
    let dialogId: String
    let msgId: Int64
    let senderAccountId: String
    let clientMsgId: String
    let kind: String
    let text: String
    let replyToMsgId: Int64?
    let forwardedFromAccountId: String?
    let forwardedFromDialogId: String?
    let forwardedFromMsgId: Int64?
    let isForwarded: Bool
    let reactions: [CloudReaction]
    let media: CloudMedia?
    let editVersion: Int
    let state: String
    let serverTs: String

    init(
        dialogId: String,
        msgId: Int64,
        senderAccountId: String,
        clientMsgId: String,
        kind: String,
        text: String,
        replyToMsgId: Int64? = nil,
        forwardedFromAccountId: String? = nil,
        forwardedFromDialogId: String? = nil,
        forwardedFromMsgId: Int64? = nil,
        isForwarded: Bool = false,
        reactions: [CloudReaction] = [],
        media: CloudMedia? = nil,
        editVersion: Int,
        state: String,
        serverTs: String
    ) {
        self.dialogId = dialogId
        self.msgId = msgId
        self.senderAccountId = senderAccountId
        self.clientMsgId = clientMsgId
        self.kind = kind
        self.text = text
        self.replyToMsgId = replyToMsgId
        self.forwardedFromAccountId = forwardedFromAccountId
        self.forwardedFromDialogId = forwardedFromDialogId
        self.forwardedFromMsgId = forwardedFromMsgId
        self.isForwarded = isForwarded
        self.reactions = reactions
        self.media = media
        self.editVersion = editVersion
        self.state = state
        self.serverTs = serverTs
    }

    enum CodingKeys: String, CodingKey {
        case dialogId = "dialog_id"
        case msgId = "msg_id"
        case senderAccountId = "sender_account_id"
        case clientMsgId = "client_msg_id"
        case kind
        case text
        case replyToMsgId = "reply_to_msg_id"
        case forwardedFromAccountId = "forwarded_from_account_id"
        case forwardedFromDialogId = "forwarded_from_dialog_id"
        case forwardedFromMsgId = "forwarded_from_msg_id"
        case isForwarded = "forwarded"
        case reactions
        case media
        case editVersion = "edit_version"
        case state
        case serverTs = "server_ts"
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        dialogId = try values.decode(String.self, forKey: .dialogId)
        msgId = try values.decode(Int64.self, forKey: .msgId)
        senderAccountId = try values.decode(String.self, forKey: .senderAccountId)
        clientMsgId = try values.decode(String.self, forKey: .clientMsgId)
        kind = try values.decode(String.self, forKey: .kind)
        text = try values.decode(String.self, forKey: .text)
        replyToMsgId = try values.decodeIfPresent(Int64.self, forKey: .replyToMsgId)
        forwardedFromAccountId = try values.decodeIfPresent(String.self, forKey: .forwardedFromAccountId)
        forwardedFromDialogId = try values.decodeIfPresent(String.self, forKey: .forwardedFromDialogId)
        forwardedFromMsgId = try values.decodeIfPresent(Int64.self, forKey: .forwardedFromMsgId)
        isForwarded = try values.decodeIfPresent(Bool.self, forKey: .isForwarded) ?? false
        reactions = try values.decodeIfPresent([CloudReaction].self, forKey: .reactions) ?? []
        media = try values.decodeIfPresent(CloudMedia.self, forKey: .media)
        editVersion = try values.decode(Int.self, forKey: .editVersion)
        state = try values.decode(String.self, forKey: .state)
        serverTs = try values.decode(String.self, forKey: .serverTs)
    }
}

nonisolated struct CloudUpdate: Codable, Sendable {
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

nonisolated struct CloudSession: Codable, Equatable, Sendable {
    let accountId: String
    let deviceId: String
    let token: String

    enum CodingKeys: String, CodingKey {
        case accountId
        case deviceId
        case token
    }
}

nonisolated struct StoredCloudSession: Codable, Equatable, Sendable {
    let session: CloudSession
    let phone: String
    let displayName: String
}

nonisolated struct AuthStartResponse: Codable, Sendable {
    let code: String?
    let retryAfter: Int?
}

nonisolated struct ContactLookupResponse: Codable, Sendable {
    let accountId: String?
    let displayName: String?
    let found: Bool?
}

nonisolated struct DirectDialogResponse: Codable, Sendable {
    let dialogId: String
    let created: Bool
}

nonisolated struct SendMessageResponse: Codable, Sendable {
    let dialogId: String
    let clientMsgId: String
    let msgId: Int64
    let senderPts: Int64
    let duplicate: Bool
    let serverTs: String?
    let text: String?
}

nonisolated struct MessageMutationResponse: Codable, Sendable {
    let dialogId: String
    let msgId: Int64
    let actorPts: Int64
    let duplicate: Bool
    let message: CloudMessage
}

nonisolated struct SyncStateResponse: Codable, Sendable {
    let pts: Int64
}

nonisolated struct DifferenceResponse: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let kind: String
    let state: State
    let updates: [CloudUpdate]?
    let hasMore: Bool?
}

nonisolated struct BootstrapStartResponse: Codable, Sendable {
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

nonisolated struct BootstrapDialogMember: Codable, Equatable, Sendable {
    let accountId: String
    let role: String
    let lastReadMsgId: Int64

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case role
        case lastReadMsgId = "last_read_msg_id"
    }
}

nonisolated struct BootstrapDialog: Codable, Equatable, Sendable {
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

nonisolated struct BootstrapDialogsPage: Codable, Sendable {
    struct State: Codable, Sendable {
        let pts: Int64
    }

    let token: String
    let state: State
    let dialogs: [BootstrapDialog]
    let nextCursor: String?
    let hasMore: Bool
}

nonisolated struct HistoryPageResponse: Codable, Sendable {
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

nonisolated struct ReadResponse: Codable, Sendable {
    let dialogId: String
    let maxReadMsgId: Int64
}

nonisolated struct PushRegistrationResponse: Codable, Sendable {
    let registered: Bool
}

nonisolated struct SessionRevocationResponse: Codable, Sendable {
    let revoked: Bool
}

nonisolated struct AccountDeletionResponse: Codable, Sendable {
    let deleted: Bool
}

nonisolated struct CloudDevice: Codable, Identifiable, Equatable, Sendable {
    let id: String
    let platform: String
    let deviceName: String?
    let createdAt: String
    let lastSeenAt: String?
    let current: Bool
}

private struct DeviceListResponse: Codable, Sendable {
    let devices: [CloudDevice]
}

nonisolated struct CloudAPIError: Error, LocalizedError {
    let status: Int
    let message: String
    let retryAfter: Int?
    var code: String? = nil
    var existingCallId: String? = nil

    var errorDescription: String? {
        message
    }
}

nonisolated struct CloudCapabilitiesResponse: Codable, Equatable, Sendable {
    let apiVersion: Int
    let capabilities: [String]

    enum CodingKeys: String, CodingKey {
        case apiVersion = "api_version"
        case capabilities
    }
}

nonisolated enum CloudFailureDisposition: Equatable, Sendable {
    case transient(retryAfter: TimeInterval?)
    case authenticationRequired
    case unsupportedServer
    case permanent
}

nonisolated func cloudFailureDisposition(_ error: Error) -> CloudFailureDisposition {
    if let urlError = error as? URLError {
        switch urlError.code {
        case .timedOut, .networkConnectionLost, .notConnectedToInternet, .cannotConnectToHost,
             .cannotFindHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed:
            return .transient(retryAfter: nil)
        default:
            return .permanent
        }
    }
    guard let apiError = error as? CloudAPIError else { return .permanent }
    switch apiError.status {
    case 401, 403:
        return .authenticationRequired
    case 404:
        return .unsupportedServer
    case 408, 425, 429, 500...599:
        return .transient(retryAfter: apiError.retryAfter.map(TimeInterval.init))
    default:
        return .permanent
    }
}

nonisolated func cloudOperationFailureDisposition(
    _ error: Error,
    serverAdvertisesFeature: Bool
) -> CloudFailureDisposition {
    if serverAdvertisesFeature, let apiError = error as? CloudAPIError, apiError.status == 404 {
        // Once the capability contract confirms a route family exists, a 404 is a missing/expired
        // resource rather than deployment drift. Retrying it forever would hide a permanent error.
        return .permanent
    }
    return cloudFailureDisposition(error)
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

    func capabilities() async throws -> CloudCapabilitiesResponse {
        try await get("v1/capabilities", token: nil)
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

    func sendMessage(
        dialogId: String,
        clientMsgId: String,
        body: String,
        replyToMsgId: Int64? = nil,
        token: String
    ) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: SendMessageRequest(
                dialogId: dialogId,
                clientMsgId: clientMsgId,
                kind: "text",
                body: body,
                replyToMsgId: replyToMsgId,
                mediaId: nil,
                forwardedFrom: nil
            ),
            token: token
        )
    }

    func sendMediaMessage(
        dialogId: String,
        clientMsgId: String,
        body: String,
        mediaId: String,
        replyToMsgId: Int64? = nil,
        token: String
    ) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: SendMessageRequest(
                dialogId: dialogId, clientMsgId: clientMsgId, kind: nil,
                body: body, replyToMsgId: replyToMsgId, mediaId: mediaId,
                forwardedFrom: nil
            ),
            token: token
        )
    }

    func forwardMessage(
        dialogId: String,
        clientMsgId: String,
        sourceDialogId: String,
        sourceMsgId: Int64,
        token: String
    ) async throws -> SendMessageResponse {
        try await post(
            "v1/messages/send",
            body: SendMessageRequest(
                dialogId: dialogId,
                clientMsgId: clientMsgId,
                kind: "text",
                body: nil,
                replyToMsgId: nil,
                mediaId: nil,
                forwardedFrom: ForwardedFromRequest(dialogId: sourceDialogId, msgId: sourceMsgId)
            ),
            token: token
        )
    }

    func editMessage(
        dialogId: String,
        msgId: Int64,
        clientMutationId: String,
        expectedEditVersion: Int,
        body: String,
        token: String
    ) async throws -> MessageMutationResponse {
        try await post(
            "v1/messages/edit",
            body: EditMessageRequest(
                dialogId: dialogId,
                msgId: msgId,
                clientMutationId: clientMutationId,
                expectedEditVersion: expectedEditVersion,
                body: body
            ),
            token: token
        )
    }

    func deleteMessage(
        dialogId: String,
        msgId: Int64,
        clientMutationId: String,
        token: String
    ) async throws -> MessageMutationResponse {
        try await post(
            "v1/messages/delete",
            body: DeleteMessageRequest(
                dialogId: dialogId,
                msgId: msgId,
                clientMutationId: clientMutationId
            ),
            token: token
        )
    }

    func setReaction(
        dialogId: String,
        msgId: Int64,
        clientMutationId: String,
        emoji: String?,
        token: String
    ) async throws -> MessageMutationResponse {
        try await post(
            "v1/messages/react",
            body: ReactionRequest(
                dialogId: dialogId,
                msgId: msgId,
                clientMutationId: clientMutationId,
                emoji: emoji
            ),
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

    func registerPushToken(_ deviceToken: String, environment: String, token: String) async throws -> PushRegistrationResponse {
        try await post(
            "v1/devices/push",
            body: PushRegistrationRequest(token: deviceToken, environment: environment),
            token: token
        )
    }

    func unregisterPushToken(token: String) async throws -> PushRegistrationResponse {
        try await delete("v1/devices/push", token: token)
    }

    func registerVoIPPushToken(
        _ deviceToken: String,
        environment: String,
        token: String
    ) async throws -> PushRegistrationResponse {
        try await put(
            "v1/devices/voip-push",
            body: PushRegistrationRequest(token: deviceToken, environment: environment),
            token: token
        )
    }

    func unregisterVoIPPushToken(token: String) async throws -> PushRegistrationResponse {
        try await delete("v1/devices/voip-push", token: token)
    }

    func createCall(_ body: CreateCloudCallRequest, token: String) async throws -> CloudCallCreateResponse {
        try await post("v1/calls", body: body, token: token, timeoutInterval: 8)
    }

    func activeCalls(token: String) async throws -> CloudActiveCallsResponse {
        try await get("v1/calls/active", token: token, timeoutInterval: 8)
    }

    func call(id: String, token: String) async throws -> CloudCallResponse {
        try await get("v1/calls/\(id)", token: token, timeoutInterval: 8)
    }

    func acceptCall(
        id: String,
        body: AcceptCloudCallRequest,
        token: String
    ) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/accept", body: body, token: token, timeoutInterval: 8)
    }

    func revealCall(
        id: String,
        body: RevealCloudCallRequest,
        token: String
    ) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/reveal", body: body, token: token, timeoutInterval: 8)
    }

    func confirmCall(
        id: String,
        body: ConfirmCloudCallRequest,
        token: String
    ) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/confirm", body: body, token: token, timeoutInterval: 8)
    }

    func declineCall(id: String, reason: String? = nil, token: String) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/decline", body: EndCloudCallRequest(reason: reason), token: token, timeoutInterval: 8)
    }

    func cancelCall(id: String, reason: String? = nil, token: String) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/cancel", body: EndCloudCallRequest(reason: reason), token: token, timeoutInterval: 8)
    }

    func endCall(id: String, reason: String? = nil, token: String) async throws -> CloudCallResponse {
        try await post("v1/calls/\(id)/end", body: EndCloudCallRequest(reason: reason), token: token, timeoutInterval: 8)
    }

    func sendCallEvent(
        callId: String,
        body: SendCloudCallEventRequest,
        token: String
    ) async throws -> CloudCallEventResponse {
        try await post("v1/calls/\(callId)/events", body: body, token: token, timeoutInterval: 8)
    }

    func callEvents(
        callId: String,
        after eventSequence: Int64,
        limit: Int = 100,
        token: String
    ) async throws -> CloudCallEventsResponse {
        try await get(
            "v1/calls/\(callId)/events",
            queryItems: [
                URLQueryItem(name: "after", value: String(max(0, eventSequence))),
                URLQueryItem(name: "limit", value: String(max(1, min(100, limit)))),
            ],
            token: token,
            timeoutInterval: 8
        )
    }

    func sendCallTelemetry(
        callId: String,
        body: CallTelemetryRequest,
        token: String
    ) async throws -> CloudCallTelemetryResponse {
        try await post("v1/calls/\(callId)/telemetry", body: body, token: token)
    }

    func callIceConfiguration(callId: String, token: String) async throws -> CloudCallIceConfiguration {
        try await get("v1/calls/\(callId)/ice-config", token: token, timeoutInterval: 8)
    }

    func blockAccount(id: String, token: String) async throws -> CloudBlockResponse {
        try await put("v1/blocks/\(id)", body: EmptyBody(), token: token)
    }

    func unblockAccount(id: String, token: String) async throws -> CloudBlockResponse {
        try await delete("v1/blocks/\(id)", token: token)
    }

    func revokeSession(token: String) async throws -> SessionRevocationResponse {
        try await delete("v1/session", token: token)
    }

    func listDevices(token: String) async throws -> [CloudDevice] {
        let response: DeviceListResponse = try await get("v1/devices", token: token)
        return response.devices
    }

    func revokeDevice(id: String, token: String) async throws -> SessionRevocationResponse {
        try await delete("v1/devices/\(id)", token: token)
    }

    func startAccountDeletion(token: String) async throws -> AuthStartResponse {
        try await post("v1/account/deletion/start", body: EmptyBody(), token: token)
    }

    func deleteAccount(code: String, token: String) async throws -> AccountDeletionResponse {
        try await delete("v1/account", body: ["code": code], token: token)
    }

    private func get<Response: Decodable>(
        _ path: String,
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        try await get(path, queryItems: [], token: token, timeoutInterval: timeoutInterval)
    }

    private func get<Response: Decodable>(
        _ path: String,
        queryItems: [URLQueryItem],
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var components = URLComponents(url: config.httpURL(path: path), resolvingAgainstBaseURL: false)!
        if !queryItems.isEmpty { components.queryItems = queryItems }
        var request = URLRequest(url: components.url!)
        request.httpMethod = "GET"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func post<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?,
        timeoutInterval: TimeInterval? = nil
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "POST"
        if let timeoutInterval { request.timeoutInterval = timeoutInterval }
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func put<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "PUT"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try encoder.encode(body)
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func delete<Response: Decodable>(_ path: String, token: String?) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "DELETE"
        if let token {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        return try await run(request)
    }

    private func delete<Body: Encodable, Response: Decodable>(
        _ path: String,
        body: Body,
        token: String?
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = "DELETE"
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
            throw CloudAPIError(status: -1, message: "Invalid server response", retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let serverError = try? decoder.decode(ServerError.self, from: data)
            let message = serverError?.error
                ?? String(data: data, encoding: .utf8)
                ?? "HTTP \(http.statusCode)"
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            throw CloudAPIError(
                status: http.statusCode,
                message: message,
                retryAfter: retryAfter,
                code: serverError?.code,
                existingCallId: serverError?.existingCallId
            )
        }
        return try decoder.decode(Response.self, from: data)
    }
}

private struct ServerError: Codable {
    let error: String
    let code: String?
    let existingCallId: String?
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

private struct SendMessageRequest: Encodable {
    let dialogId: String
    let clientMsgId: String
    let kind: String?
    let body: String?
    let replyToMsgId: Int64?
    let mediaId: String?
    let forwardedFrom: ForwardedFromRequest?
}

private struct ForwardedFromRequest: Encodable {
    let dialogId: String
    let msgId: Int64
}

private struct EditMessageRequest: Encodable {
    let dialogId: String
    let msgId: Int64
    let clientMutationId: String
    let expectedEditVersion: Int
    let body: String
}

private struct DeleteMessageRequest: Encodable {
    let dialogId: String
    let msgId: Int64
    let clientMutationId: String
}

private struct ReactionRequest: Encodable {
    let dialogId: String
    let msgId: Int64
    let clientMutationId: String
    let emoji: String?
}

private struct ReadRequest: Encodable {
    let dialogId: String
    let maxReadMsgId: Int64
}

private struct PushRegistrationRequest: Encodable {
    let token: String
    let environment: String
}
