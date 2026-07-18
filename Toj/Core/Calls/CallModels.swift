import Foundation

/// The participant's role is fixed for the lifetime of a call. It is also used
/// to select directional signaling keys, so it must never be inferred from UI
/// state or message arrival order.
nonisolated enum CallRole: String, Codable, CaseIterable, Sendable {
    case caller
    case callee
}

nonisolated enum CallDirection: String, Codable, Sendable {
    case outgoing
    case incoming
}

nonisolated enum CallGlarePushDisposition: Equatable, Sendable {
    case deferForServerWinner
    case declineAsBusy
}

nonisolated enum CallGlarePivotSource: Equatable, Sendable {
    case alreadyReportedInvitation
    case syntheticInvitation
}

/// Pure policy for the two orderings of a simultaneous cross-call. Keeping the decision outside
/// CallKit makes the timing contract deterministic and directly testable.
nonisolated enum CallGlarePolicy {
    static func pushDisposition(
        activeCallId: UUID,
        incomingCallId: UUID,
        activeDirection: CallDirection,
        activePeerAccountId: String,
        incomingCallerAccountId: String,
        activeCallReachedServer: Bool
    ) -> CallGlarePushDisposition {
        guard activeCallId != incomingCallId,
              activeDirection == .outgoing,
              !activeCallReachedServer,
              activePeerAccountId == incomingCallerAccountId else {
            return .declineAsBusy
        }
        return .deferForServerWinner
    }

    static func pivotSource(
        existingCallId: UUID,
        deferredInvitationIds: Set<UUID>
    ) -> CallGlarePivotSource {
        deferredInvitationIds.contains(existingCallId)
            ? .alreadyReportedInvitation
            : .syntheticInvitation
    }
}

nonisolated enum CallPrivacyMode: String, Codable, CaseIterable, Sendable {
    /// Race direct and relay candidates, then let ICE select the best path.
    case fastestRoute = "fastest_route"
    /// Gather and signal relay candidates only. No host or server-reflexive
    /// candidate may leave the WebRTC adapter in this mode.
    case relayOnly = "relay_only"
}

nonisolated enum CallEndReason: String, Codable, CaseIterable, Sendable {
    case declined
    case cancelled
    case busy
    case unanswered
    case answeredElsewhere = "answered_elsewhere"
    case remoteEnded = "remote_ended"
    case networkLost = "network_lost"
    case securityError = "security_error"
    case permissionDenied = "permission_denied"
    case failed
}

/// Product-level call state. Transport and CallKit details are deliberately
/// kept out of this type so the UI can render a single deterministic model.
nonisolated enum CallState: String, Codable, CaseIterable, Sendable {
    case idle
    case preparing
    case outgoingRinging = "outgoing_ringing"
    case incomingRinging = "incoming_ringing"
    case keyExchange = "key_exchange"
    case connecting
    case active
    case reconnecting
    case ending
    case ended

    var isTerminal: Bool {
        self == .ended
    }

    var isInProgress: Bool {
        self != .idle && self != .ended
    }
}

nonisolated struct CallParty: Codable, Equatable, Sendable {
    let accountId: String
    let deviceId: String

    enum CodingKeys: String, CodingKey {
        case accountId = "account_id"
        case deviceId = "device_id"
    }
}

nonisolated struct CallIdentity: Codable, Equatable, Sendable {
    let callId: String
    let dialogId: String
    let caller: CallParty
    let calleeAccountId: String

    enum CodingKeys: String, CodingKey {
        case callId = "call_id"
        case dialogId = "dialog_id"
        case caller
        case calleeAccountId = "callee_account_id"
    }
}
