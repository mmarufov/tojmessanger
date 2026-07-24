import Foundation

nonisolated enum CallCameraPermissionState: Equatable, Sendable {
    case notDetermined
    case denied
    case restricted
    case authorized
}

nonisolated enum CallVideoThermalState: Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool {
        let order: [Self] = [.nominal, .fair, .serious, .critical]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

nonisolated struct CallVideoCaptureDecision: Equatable, Sendable {
    let shouldCapture: Bool
    let effectiveState: CallVideoEffectiveState
    let genericPauseReason: CallVideoGenericPauseReason?
    let preferredCameraPosition: CallCameraPosition
}

/// The single serialized owner of camera intent and every asynchronous blocker. Permission and
/// capture callbacks carry `generation`; callbacks from a replaced or ended runtime are ignored.
struct CallVideoStateReducer {
    private(set) var generation: UInt64 = 0
    private(set) var userWantsCamera = false
    private(set) var preferredCameraPosition: CallCameraPosition = .front
    private(set) var secureMediaReady = false
    private(set) var permission: CallCameraPermissionState = .notDetermined
    private(set) var owningSceneIsForeground = false
    private(set) var pictureInPictureIsActive = false
    private(set) var backgroundCameraIsAvailable = false
    private(set) var captureIsInterrupted = false
    private(set) var captureRuntimeFailed = false
    private(set) var cameraIsAvailable = true
    private(set) var systemPressureIsCritical = false
    private(set) var thermalState: CallVideoThermalState = .nominal
    private(set) var networkIsStarved = false
    private var thermalRecoveryBeganAt: Date?
    private var requiresThermalRecovery = false

    @discardableResult
    mutating func beginRuntime(initialCameraIntent: Bool, preferredPosition: CallCameraPosition = .front) -> UInt64 {
        generation &+= 1
        userWantsCamera = initialCameraIntent
        preferredCameraPosition = preferredPosition
        secureMediaReady = false
        owningSceneIsForeground = false
        pictureInPictureIsActive = false
        backgroundCameraIsAvailable = false
        captureIsInterrupted = false
        captureRuntimeFailed = false
        cameraIsAvailable = true
        systemPressureIsCritical = false
        thermalState = .nominal
        networkIsStarved = false
        thermalRecoveryBeganAt = nil
        requiresThermalRecovery = false
        return generation
    }

    mutating func endRuntime() {
        generation &+= 1
        userWantsCamera = false
        secureMediaReady = false
        captureIsInterrupted = false
        pictureInPictureIsActive = false
    }

    mutating func setUserWantsCamera(_ value: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        userWantsCamera = value
    }

    mutating func setPreferredCameraPosition(_ value: CallCameraPosition, generation: UInt64) {
        guard generation == self.generation else { return }
        preferredCameraPosition = value
    }

    mutating func setSecureMediaReady(_ value: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        secureMediaReady = value
    }

    mutating func setPermission(_ value: CallCameraPermissionState, generation: UInt64) {
        guard generation == self.generation else { return }
        permission = value
    }

    mutating func setScene(foreground: Bool, pictureInPicture: Bool, backgroundCameraAvailable: Bool,
                  generation: UInt64) {
        guard generation == self.generation else { return }
        owningSceneIsForeground = foreground
        pictureInPictureIsActive = pictureInPicture
        backgroundCameraIsAvailable = backgroundCameraAvailable
    }

    mutating func setCaptureHealth(interrupted: Bool, runtimeFailed: Bool, cameraAvailable: Bool,
                          pressureCritical: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        captureIsInterrupted = interrupted
        captureRuntimeFailed = runtimeFailed
        cameraIsAvailable = cameraAvailable
        systemPressureIsCritical = pressureCritical
    }

    /// A foreground user retry may clear a latched runtime error, but it must not override an
    /// active interruption, unavailable camera, or system-pressure blocker.
    mutating func retryCaptureAfterRuntimeFailure(generation: UInt64) {
        guard generation == self.generation else { return }
        captureRuntimeFailed = false
    }

    mutating func setNetworkStarved(_ value: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        networkIsStarved = value
    }

    mutating func setThermalState(_ value: CallVideoThermalState, now: Date, generation: UInt64) {
        guard generation == self.generation else { return }
        let previous = thermalState
        thermalState = value
        if value == .critical {
            requiresThermalRecovery = true
            thermalRecoveryBeganAt = nil
        } else if requiresThermalRecovery, value <= .fair {
            if previous > .fair || thermalRecoveryBeganAt == nil {
                thermalRecoveryBeganAt = now
            }
        } else if requiresThermalRecovery {
            thermalRecoveryBeganAt = nil
        }
    }

    mutating func decision(now: Date = Date()) -> CallVideoCaptureDecision {
        guard userWantsCamera else { return makeDecision(false, .inactive, nil) }
        guard secureMediaReady, permission == .authorized else {
            return makeDecision(false, .inactive, .unavailable)
        }
        let backgroundPermitted = owningSceneIsForeground
            || (pictureInPictureIsActive && backgroundCameraIsAvailable)
        guard backgroundPermitted else { return makeDecision(false, .paused, .background) }
        guard cameraIsAvailable, !captureIsInterrupted, !captureRuntimeFailed,
              !systemPressureIsCritical else {
            return makeDecision(false, .paused, .unavailable)
        }
        if thermalState == .critical { return makeDecision(false, .paused, .unavailable) }
        if requiresThermalRecovery {
            guard let thermalRecoveryBeganAt,
                  now.timeIntervalSince(thermalRecoveryBeganAt) >= 20 else {
                return makeDecision(false, .paused, .unavailable)
            }
            requiresThermalRecovery = false
            self.thermalRecoveryBeganAt = nil
        }
        guard !networkIsStarved else { return makeDecision(false, .paused, .network) }
        return makeDecision(true, .active, nil)
    }

    private func makeDecision(
        _ capture: Bool,
        _ state: CallVideoEffectiveState,
        _ reason: CallVideoGenericPauseReason?
    ) -> CallVideoCaptureDecision {
        CallVideoCaptureDecision(
            shouldCapture: capture,
            effectiveState: state,
            genericPauseReason: reason,
            preferredCameraPosition: preferredCameraPosition
        )
    }
}

nonisolated enum CallNetworkPathKind: Sendable {
    case wifi
    case cellular
    case wired
    case other
}

nonisolated struct CallVideoPathPolicy: Sendable {
    let kind: CallNetworkPathKind
    let isConstrained: Bool
    let isLowDataMode: Bool
    let isRoaming: Bool
}

nonisolated struct CallVideoSenderStats: Sendable {
    let timestamp: TimeInterval
    let packetsLost: Int64?
    let packetsSent: Int64?
    let roundTripTimeMilliseconds: Double?
    let jitterMilliseconds: Double?
    let availableOutgoingBitrate: Double?
}

nonisolated struct CallVideoReceiverStats: Sendable {
    let timestamp: TimeInterval
    let packetsLost: Int64?
    let packetsReceived: Int64?
    let jitterMilliseconds: Double?
    let totalFreezeMilliseconds: Double?
    let totalFramesDecoded: Int64?
}

nonisolated enum CallMediaRevisionPolicy {
    static func advanced(after revision: UInt64) throws -> UInt64 {
        guard revision < UInt64.max else { throw CallCryptoError.sequenceExhausted }
        return revision + 1
    }

    static func accepts(remote revision: UInt64, highestAccepted: UInt64) -> Bool {
        revision > highestAccepted
    }
}

/// Pure one-second quality reducer. Packet, frame, and freeze counters are converted to interval
/// deltas before thresholds are evaluated; resets are explicit after path/ICE/camera changes.
nonisolated struct CallVideoQualityReducer: Sendable {
    private(set) var senderTier: CallVideoQualityTier = .high
    private(set) var requestedReceiveTier: CallVideoQualityTier = .high
    private(set) var outgoingVideoPaused = false

    private var lastSender: CallVideoSenderStats?
    private var lastReceiver: CallVideoReceiverStats?
    private var senderBadCount = 0
    private var senderHealthyCount = 0
    private var senderMissingCount = 0
    private var starvationCount = 0
    private var recoveryCount = 0
    private var receiverBadCount = 0
    private var receiverHealthyCount = 0
    private var receiverMissingCount = 0

    mutating func resetBaselines() {
        lastSender = nil
        lastReceiver = nil
        senderBadCount = 0
        senderHealthyCount = 0
        senderMissingCount = 0
        starvationCount = 0
        recoveryCount = 0
        receiverBadCount = 0
        receiverHealthyCount = 0
        receiverMissingCount = 0
    }

    mutating func ingestSender(
        _ sample: CallVideoSenderStats?,
        policy: CallDataUsagePolicy,
        path: CallVideoPathPolicy,
        thermal: CallVideoThermalState,
        peerMaximumReceiveTier: CallVideoQualityTier
    ) {
        let policyCap = maximumTier(policy: policy, path: path, thermal: thermal)
        let effectiveCap = min(policyCap, peerMaximumReceiveTier)
        if senderTier > effectiveCap { senderTier = effectiveCap }
        if thermal == .critical { outgoingVideoPaused = true }

        guard let sample else {
            senderMissingCount += 1
            senderBadCount = 0
            senderHealthyCount = 0
            if senderMissingCount >= 3 { senderTier = .low }
            return
        }
        defer { lastSender = sample }
        guard let previous = lastSender, sample.timestamp > previous.timestamp,
              let lost = intervalDelta(sample.packetsLost, previous.packetsLost),
              let sent = intervalDelta(sample.packetsSent, previous.packetsSent) else {
            senderMissingCount += 1
            senderBadCount = 0
            senderHealthyCount = 0
            if senderMissingCount >= 3 { senderTier = .low }
            return
        }
        senderMissingCount = 0
        let loss = sent > 0 ? min(1, Double(lost) / Double(sent)) : 0
        let rtt = sample.roundTripTimeMilliseconds
        let jitter = sample.jitterMilliseconds
        let available = sample.availableOutgoingBitrate
        let bad = loss > 0.08 || rtt.map { $0 > 450 } == true
            || jitter.map { $0 > 60 } == true
            || available.map { $0 < Double(senderTier.maximumBitrate) * 0.70 } == true
        let nextTier = tierAbove(senderTier)
        let healthy = loss < 0.02 && rtt.map { $0 < 250 } == true
            && jitter.map { $0 < 30 } == true
            && nextTier.map { next in
                available.map { $0 >= Double(next.maximumBitrate) * 1.25 } == true
            } == true

        senderBadCount = bad ? senderBadCount + 1 : 0
        senderHealthyCount = healthy ? senderHealthyCount + 1 : 0
        if senderBadCount >= 3 {
            senderTier = max(.low, tierBelow(senderTier))
            senderBadCount = 0
            senderHealthyCount = 0
        } else if senderHealthyCount >= 10, let raised = tierAbove(senderTier) {
            senderTier = min(raised, effectiveCap)
            senderHealthyCount = 0
            senderBadCount = 0
        }

        if available.map({ $0 < 80_000 }) == true {
            starvationCount += 1
            recoveryCount = 0
            if starvationCount >= 5 { outgoingVideoPaused = true }
        } else if outgoingVideoPaused,
                  available.map({ $0 > 160_000 }) == true,
                  loss <= 0.08,
                  rtt.map({ $0 <= 450 }) == true {
            recoveryCount += 1
            starvationCount = 0
            if recoveryCount >= 10, thermal != .critical {
                outgoingVideoPaused = false
                recoveryCount = 0
            }
        } else {
            starvationCount = 0
            recoveryCount = 0
        }
    }

    mutating func ingestReceiver(
        _ sample: CallVideoReceiverStats?,
        policy: CallDataUsagePolicy,
        path: CallVideoPathPolicy,
        thermal: CallVideoThermalState
    ) {
        let receiveCap = maximumTier(policy: policy, path: path, thermal: thermal)
        if requestedReceiveTier > receiveCap { requestedReceiveTier = receiveCap }
        let targetFPS = requestedReceiveTier.framesPerSecond
        guard let sample else {
            receiverMissingCount += 1
            receiverBadCount = 0
            receiverHealthyCount = 0
            if receiverMissingCount >= 3 { requestedReceiveTier = .low }
            return
        }
        guard let previous = lastReceiver else {
            lastReceiver = sample
            receiverMissingCount = 0
            receiverBadCount = 0
            receiverHealthyCount = 0
            return
        }
        defer { lastReceiver = sample }
        guard sample.timestamp > previous.timestamp,
              let lost = intervalDelta(sample.packetsLost, previous.packetsLost),
              let received = intervalDelta(sample.packetsReceived, previous.packetsReceived),
              let frames = intervalDelta(sample.totalFramesDecoded, previous.totalFramesDecoded),
              let freeze = intervalDelta(sample.totalFreezeMilliseconds, previous.totalFreezeMilliseconds)
        else {
            receiverMissingCount += 1
            receiverBadCount = 0
            receiverHealthyCount = 0
            if receiverMissingCount >= 3 { requestedReceiveTier = .low }
            return
        }
        receiverMissingCount = 0
        let seconds = sample.timestamp - previous.timestamp
        let total = lost + received
        let loss = total > 0 ? Double(lost) / Double(total) : 0
        let decodedFPS = Double(frames) / seconds
        let bad = loss > 0.08 || sample.jitterMilliseconds.map { $0 > 60 } == true
            || freeze > 500 || decodedFPS < Double(targetFPS) * 0.50
        let healthy = loss < 0.02 && sample.jitterMilliseconds.map { $0 < 30 } == true
            && freeze == 0 && decodedFPS > Double(targetFPS) * 0.80
        receiverBadCount = bad ? receiverBadCount + 1 : 0
        receiverHealthyCount = healthy ? receiverHealthyCount + 1 : 0
        if receiverBadCount >= 3 {
            requestedReceiveTier = tierBelow(requestedReceiveTier)
            receiverBadCount = 0
            receiverHealthyCount = 0
        } else if receiverHealthyCount >= 10 {
            requestedReceiveTier = min(tierAbove(requestedReceiveTier) ?? .high, receiveCap)
            receiverHealthyCount = 0
            receiverBadCount = 0
        }
    }

    func maximumTier(
        policy: CallDataUsagePolicy,
        path: CallVideoPathPolicy,
        thermal: CallVideoThermalState
    ) -> CallVideoQualityTier {
        if path.isConstrained || path.isLowDataMode || path.isRoaming { return .low }
        if thermal == .critical { return .low }
        if thermal == .serious { return .medium }
        switch policy {
        case .never: return .high
        case .cellularOnly: return path.kind == .cellular ? .medium : .high
        case .always: return .medium
        }
    }

    private func intervalDelta(_ current: Int64?, _ previous: Int64?) -> Int64? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }

    private func intervalDelta(_ current: Double?, _ previous: Double?) -> Double? {
        guard let current, let previous, current >= previous else { return nil }
        return current - previous
    }

    private func tierBelow(_ tier: CallVideoQualityTier) -> CallVideoQualityTier {
        switch tier { case .high: .medium; case .medium, .low: .low }
    }

    private func tierAbove(_ tier: CallVideoQualityTier) -> CallVideoQualityTier? {
        switch tier { case .low: .medium; case .medium: .high; case .high: nil }
    }
}
