import Foundation
@preconcurrency import PushKit

nonisolated struct VoIPPushInvitation: Equatable, Sendable {
    let callId: UUID
    let callerAccountId: String
    let initialKind: CallInitialKind
    let expiresAt: Date?

    nonisolated init(
        callId: UUID,
        callerAccountId: String,
        initialKind: CallInitialKind,
        expiresAt: Date?
    ) {
        self.callId = callId
        self.callerAccountId = callerAccountId
        self.initialKind = initialKind
        self.expiresAt = expiresAt
    }

    nonisolated init?(payload: [AnyHashable: Any], now: Date = Date()) {
        let values = (payload["toj"] as? [String: Any]).map {
            Dictionary(uniqueKeysWithValues: $0.map { (AnyHashable($0.key), $0.value) })
        } ?? payload

        func string(_ snakeCase: String, _ camelCase: String) -> String? {
            (values[snakeCase] as? String) ?? (values[camelCase] as? String)
        }

        guard (values["v"] as? NSNumber)?.intValue == 1,
              let type = string("type", "type") else { return nil }
        let initialKind: CallInitialKind
        switch type {
        case "voice_call": initialKind = .voice
        case "video_call": initialKind = .video
        default: return nil
        }

        guard
            let rawCallId = string("call_id", "callId"),
            let callId = UUID(uuidString: rawCallId),
            let callerAccountId = string("caller_account_id", "callerAccountId")?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !callerAccountId.isEmpty
        else { return nil }

        let expiresAt: Date?
        if let seconds = values["expires_at"] as? TimeInterval
            ?? values["expiresAt"] as? TimeInterval {
            expiresAt = Date(timeIntervalSince1970: seconds)
        } else if let rawExpiry = string("expires_at", "expiresAt") {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            expiresAt = formatter.date(from: rawExpiry) ?? ISO8601DateFormatter().date(from: rawExpiry)
        } else {
            expiresAt = nil
        }
        self.callId = callId
        self.callerAccountId = callerAccountId
        self.initialKind = initialKind
        self.expiresAt = expiresAt
    }

}

nonisolated enum VoIPPushRoutingDecision: Equatable, Sendable {
    case invitation(VoIPPushInvitation)
    case invalidPayloadRequiresFallbackReport

    nonisolated init(payload: [AnyHashable: Any]) {
        if let invitation = VoIPPushInvitation(payload: payload) {
            self = .invitation(invitation)
        } else {
            self = .invalidPayloadRequiresFallbackReport
        }
    }
}

/// PushKit has its own token and APNs topic. It intentionally does not share state with the
/// ordinary notification registrar because VoIP pushes must keep working without alert permission.
@MainActor
final class VoIPPushRegistrationCenter: NSObject, PKPushRegistryDelegate {
    static let shared = VoIPPushRegistrationCenter()

    typealias TokenHandler = (_ token: String?, _ environment: String) async -> Void

    private var registry: PKPushRegistry?
    private var tokenHandler: TokenHandler?
    private var currentToken: String?

    nonisolated static var isEnabled: Bool { PushRegistrationCenter.isEnabled }

    static var environment: String { PushRegistrationCenter.environment }

    func install() {
        guard Self.isEnabled, registry == nil else { return }
        let registry = PKPushRegistry(queue: .main)
        registry.delegate = self
        registry.desiredPushTypes = [.voIP]
        self.registry = registry
    }

    func bind(tokenHandler: @escaping TokenHandler) {
        self.tokenHandler = tokenHandler
        if let currentToken {
            Task { await tokenHandler(currentToken, Self.environment) }
        }
    }

    func refreshRegistration() {
        install()
        guard let currentToken, let tokenHandler else { return }
        Task { await tokenHandler(currentToken, Self.environment) }
    }

    func unbind() {
        tokenHandler = nil
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didUpdate pushCredentials: PKPushCredentials,
        for type: PKPushType
    ) {
        guard type == .voIP else { return }
        let token = PushRegistrationCenter.hexadecimalToken(from: pushCredentials.token)
        Task { @MainActor in
            currentToken = token
            if let tokenHandler {
                await tokenHandler(token, Self.environment)
            }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didInvalidatePushTokenFor type: PKPushType
    ) {
        guard type == .voIP else { return }
        Task { @MainActor in
            currentToken = nil
            if let tokenHandler {
                await tokenHandler(nil, Self.environment)
            }
        }
    }

    nonisolated func pushRegistry(
        _ registry: PKPushRegistry,
        didReceiveIncomingPushWith payload: PKPushPayload,
        for type: PKPushType,
        completion: @escaping () -> Void
    ) {
        guard type == .voIP else {
            completion()
            return
        }

        let completion = VoIPPushCompletion(completion)
        Task { @MainActor in
            switch VoIPPushRoutingDecision(payload: payload.dictionaryPayload) {
            case .invitation(let invitation):
                // CallCoordinator reports CallKit before it performs any network reconciliation.
                await CallCoordinator.shared.receiveVoIPPush(invitation)
            case .invalidPayloadRequiresFallbackReport:
                // iOS requires every delivered VoIP push to result in a CallKit report. Never
                // include the rejected payload or its metadata in diagnostics.
                NSLog("Rejected an invalid VoIP push payload")
                await CallCoordinator.shared.receiveInvalidVoIPPush()
            }
            completion.call()
        }
    }
}

private nonisolated final class VoIPPushCompletion: @unchecked Sendable {
    private let closure: () -> Void

    init(_ closure: @escaping () -> Void) {
        self.closure = closure
    }

    func call() { closure() }
}
