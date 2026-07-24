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

/// Immutable user intent captured when the server call is created. This is deliberately
/// independent from the negotiated media profile: an audio-start call may negotiate profile 2
/// so its camera can be enabled later without renegotiation.
nonisolated enum CallInitialKind: String, Codable, CaseIterable, Sendable {
    case voice
    case video
}

nonisolated struct CallDeviceCapabilities: Codable, Equatable, Sendable {
    let supportedCallProtocolVersions: [UInt16]
    let supportedCallMediaProfileVersions: [UInt16]
    let callViewVersion: UInt16
}

nonisolated enum CallDataUsagePolicy: String, Codable, CaseIterable, Sendable {
    case never
    case cellularOnly = "cellular_only"
    case always
}

nonisolated enum CallVideoSourceKind: String, Codable, Sendable {
    case camera
}

nonisolated enum CallCameraPosition: String, Codable, CaseIterable, Sendable {
    case front
    case back
}

nonisolated enum CallVideoQualityTier: String, Codable, CaseIterable, Comparable, Sendable {
    case low
    case medium
    case high

    static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.low, .medium, .high]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }

    var captureWidth: Int {
        switch self { case .high: 1_280; case .medium: 640; case .low: 320 }
    }

    var captureHeight: Int {
        switch self { case .high: 720; case .medium: 360; case .low: 180 }
    }

    var framesPerSecond: Int {
        switch self { case .high: 30; case .medium: 24; case .low: 15 }
    }

    var maximumBitrate: Int {
        switch self { case .high: 1_500_000; case .medium: 600_000; case .low: 180_000 }
    }
}

nonisolated enum CallVideoEffectiveState: String, Codable, Sendable {
    case active
    case paused
    case inactive
}

/// Intentionally coarse. Detailed lifecycle, thermal, permission, and network diagnostics stay
/// device-local instead of becoming server-visible metadata.
nonisolated enum CallVideoGenericPauseReason: String, Codable, Sendable {
    case unavailable
    case background
    case network
}

nonisolated struct CallMediaStateUpdateV1: Codable, Equatable, Sendable {
    static let currentVersion: UInt16 = 1

    let version: UInt16
    let revision: UInt64
    let desiredCameraState: Bool
    let effectiveState: CallVideoEffectiveState
    let genericPauseReason: CallVideoGenericPauseReason?
    let requestedMaximumReceiveTier: CallVideoQualityTier
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
