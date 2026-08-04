import Foundation

nonisolated enum GroupCallPermissionState: String, Codable, Equatable, Sendable {
    case undetermined
    case denied
    case granted
}

nonisolated enum GroupCallThermalState: Int, Codable, Comparable, Sendable {
    case nominal
    case fair
    case serious
    case critical

    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

nonisolated enum GroupCallNetworkClass: String, Codable, Equatable, Sendable {
    case wifi
    case cellular
    case constrained
    case roaming
    case offline
}

nonisolated struct GroupCallSenderSample: Equatable, Sendable {
    let packetLossPercent: Double
    let roundTripMilliseconds: Double
    let jitterMilliseconds: Double
    let availableOutgoingBitrate: Int
}

nonisolated struct GroupCallMediaDecision: Equatable, Sendable {
    let cameraActive: Bool
    let cameraPauseReason: String?
    let qualityTier: GroupCallQualityTier
    let microphoneActive: Bool
    let screenShareAllowed: Bool
}

/// A pure, serialized policy reducer. Async camera/permission/ReplayKit callbacks carry
/// `generation`; a callback from a replaced or ended room is ignored rather than resurrecting
/// capture after teardown.
nonisolated struct GroupCallMediaReducer: Equatable, Sendable {
    private(set) var generation: UInt64 = 1
    private(set) var userWantsCamera = false
    private(set) var userWantsMicrophone = false
    private(set) var userWantsScreenShare = false
    private(set) var preferredCamera: GroupCallCameraPosition = .front
    private(set) var cameraPermission: GroupCallPermissionState = .undetermined
    private(set) var microphonePermission: GroupCallPermissionState = .undetermined
    private(set) var isForeground = true
    private(set) var secureMediaReady = false
    private(set) var captureInterrupted = false
    private(set) var systemPressure = false
    private(set) var thermalState: GroupCallThermalState = .nominal
    private(set) var networkClass: GroupCallNetworkClass = .wifi
    private(set) var dataUsagePolicy: CallDataUsagePolicy = .cellularOnly
    private(set) var qualityTier: GroupCallQualityTier = .high
    private(set) var networkPaused = false
    private(set) var screenExtensionReady = false
    private(set) var screenLeaseHeld = false
    private(set) var badSamples = 0
    private(set) var healthySamples = 0
    private(set) var missingSamples = 0
    private(set) var starvationSamples = 0
    private(set) var recoverySamples = 0
    private(set) var nominalThermalSince: Date?
    private(set) var recoveringFromCriticalThermal = false

    mutating func beginRuntime() -> UInt64 {
        generation &+= 1
        if generation == 0 { generation = 1 }
        secureMediaReady = false
        userWantsScreenShare = false
        screenLeaseHeld = false
        networkPaused = false
        resetNetworkHysteresis()
        return generation
    }

    mutating func endRuntime() {
        generation &+= 1
        if generation == 0 { generation = 1 }
        userWantsCamera = false
        userWantsMicrophone = false
        userWantsScreenShare = false
        secureMediaReady = false
        screenLeaseHeld = false
        resetNetworkHysteresis()
    }

    mutating func setSecureMediaReady(_ ready: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        secureMediaReady = ready
    }

    mutating func setCameraIntent(_ enabled: Bool) { userWantsCamera = enabled }
    mutating func setMicrophoneIntent(_ enabled: Bool) { userWantsMicrophone = enabled }
    mutating func setScreenShareIntent(_ enabled: Bool) { userWantsScreenShare = enabled }

    mutating func switchCamera() {
        preferredCamera = preferredCamera == .front ? .back : .front
    }

    mutating func setPermissions(
        camera: GroupCallPermissionState? = nil,
        microphone: GroupCallPermissionState? = nil,
        generation: UInt64
    ) {
        guard generation == self.generation else { return }
        if let camera { cameraPermission = camera }
        if let microphone { microphonePermission = microphone }
    }

    mutating func setForeground(_ value: Bool) { isForeground = value }
    mutating func setCaptureInterrupted(_ value: Bool) { captureInterrupted = value }
    mutating func setSystemPressure(_ value: Bool) { systemPressure = value }
    mutating func setScreenExtensionReady(_ value: Bool) { screenExtensionReady = value }

    mutating func setScreenLeaseHeld(_ value: Bool, generation: UInt64) {
        guard generation == self.generation else { return }
        screenLeaseHeld = value
    }

    mutating func setNetworkClass(_ value: GroupCallNetworkClass) {
        guard networkClass != value else { return }
        networkClass = value
        resetNetworkHysteresis()
        if value == .constrained || value == .roaming { qualityTier = .low }
    }

    mutating func setDataUsagePolicy(_ value: CallDataUsagePolicy) {
        dataUsagePolicy = value
    }

    mutating func resetNetworkAdaptation() {
        resetNetworkHysteresis()
    }

    mutating func setThermalState(_ value: GroupCallThermalState, now: Date) {
        if recoveringFromCriticalThermal,
           let since = nominalThermalSince,
           now.timeIntervalSince(since) >= 20,
           thermalState <= .fair {
            recoveringFromCriticalThermal = false
        }
        thermalState = value
        if value == .critical {
            recoveringFromCriticalThermal = true
            nominalThermalSince = nil
        } else if recoveringFromCriticalThermal {
            if value <= .fair {
                nominalThermalSince = nominalThermalSince ?? now
            } else {
                nominalThermalSince = nil
            }
        } else {
            nominalThermalSince = nil
        }
    }

    mutating func recordSenderSample(_ sample: GroupCallSenderSample?) {
        guard let sample else {
            missingSamples += 1
            badSamples = 0
            healthySamples = 0
            if missingSamples >= 3 { qualityTier = .low }
            return
        }
        missingSamples = 0
        let cap = qualityTier.maximumVideoBitrate
        let bad = sample.packetLossPercent > 8
            || sample.roundTripMilliseconds > 450
            || sample.jitterMilliseconds > 60
            || sample.availableOutgoingBitrate < Int(Double(cap) * 0.7)
        let nextTier = GroupCallQualityTier(rawValue: qualityTier.rawValue + 1)
        let healthy = sample.packetLossPercent < 2
            && sample.roundTripMilliseconds < 250
            && sample.jitterMilliseconds < 30
            && nextTier.map {
                sample.availableOutgoingBitrate >= Int(Double($0.maximumVideoBitrate) * 1.25)
            } ?? true

        badSamples = bad ? badSamples + 1 : 0
        healthySamples = healthy ? healthySamples + 1 : 0
        if badSamples >= 3, let lower = GroupCallQualityTier(rawValue: qualityTier.rawValue - 1) {
            qualityTier = lower
            badSamples = 0
            healthySamples = 0
        } else if healthySamples >= 10,
                  let higher = GroupCallQualityTier(rawValue: qualityTier.rawValue + 1) {
            qualityTier = higher
            badSamples = 0
            healthySamples = 0
        }

        if sample.availableOutgoingBitrate < 80_000 {
            starvationSamples += 1
            recoverySamples = 0
            if starvationSamples >= 5 { networkPaused = true }
        } else if sample.availableOutgoingBitrate > 160_000,
                  sample.packetLossPercent < 8,
                  sample.roundTripMilliseconds < 450 {
            starvationSamples = 0
            recoverySamples += 1
            if recoverySamples >= 10 { networkPaused = false }
        } else {
            starvationSamples = 0
            recoverySamples = 0
        }
    }

    func decision(now: Date) -> GroupCallMediaDecision {
        let thermalRecoveryReady = !recoveringFromCriticalThermal
            || (
                thermalState <= .fair
                    && nominalThermalSince.map { now.timeIntervalSince($0) >= 20 } == true
            )
        let cameraBlocker: String? = if !userWantsCamera {
            "user_off"
        } else if cameraPermission != .granted {
            "permission"
        } else if !secureMediaReady {
            "security"
        } else if !isForeground {
            "background"
        } else if captureInterrupted || systemPressure {
            "camera_unavailable"
        } else if thermalState == .critical || !thermalRecoveryReady {
            "thermal"
        } else if networkClass == .offline || networkPaused {
            "network"
        } else {
            nil
        }

        var cappedTier = qualityTier
        if networkClass == .constrained || networkClass == .roaming { cappedTier = .low }
        if dataUsagePolicy == .always, cappedTier > .medium { cappedTier = .medium }
        if dataUsagePolicy == .cellularOnly,
           networkClass == .cellular,
           cappedTier > .medium {
            cappedTier = .medium
        }
        if thermalState == .serious, cappedTier > .medium { cappedTier = .medium }
        if thermalState == .critical { cappedTier = .low }

        // Critical thermal recovery is deliberately sticky for 20 seconds at fair/nominal.
        let thermalAllowsCapture = thermalState != .critical && thermalRecoveryReady

        return GroupCallMediaDecision(
            cameraActive: cameraBlocker == nil && thermalAllowsCapture,
            cameraPauseReason: cameraBlocker,
            qualityTier: cappedTier,
            microphoneActive: userWantsMicrophone
                && microphonePermission == .granted
                && secureMediaReady,
            screenShareAllowed: userWantsScreenShare
                && secureMediaReady
                && screenExtensionReady
                && screenLeaseHeld
                && thermalState != .critical
                && networkClass != .offline
        )
    }

    private mutating func resetNetworkHysteresis() {
        badSamples = 0
        healthySamples = 0
        missingSamples = 0
        starvationSamples = 0
        recoverySamples = 0
    }
}
