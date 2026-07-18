import AVFoundation
import Foundation

#if canImport(WebRTC)
@preconcurrency import WebRTC
#endif

#if canImport(WebRTC)

/// Audio-only adapter around the pinned, official WebRTC iOS framework.
///
/// The adapter is main-actor isolated so all mutations of the ObjC WebRTC
/// graph are serialized. WebRTC invokes delegate methods on its own threads;
/// those callbacks immediately hop back to the main actor before touching
/// state or emitting events.
@MainActor
final class WebRTCVoiceEngine: NSObject, WebRTCEngine {
    /// The encrypted signaling plaintext limit is 64 KiB. SDP is restricted
    /// to ASCII and 30 KiB, so even the worst case where every byte requires
    /// JSON escaping remains below that limit with the wire envelope included.
    private static let maximumSignaledSDPBytes = 30 * 1_024
    private static let maximumCandidateBytes = 2_048
    /// This is a ceiling, not a target. WebRTC's congestion controller and
    /// Opus continue adapting below 32 kbps (including constrained ~20 kbps
    /// operation) from packet loss, RTT, and available-bandwidth feedback.
    private static let maximumAudioBitrateBps = 32_000

    private static let initializeSSLOnce: Bool = {
        RTCInitializeSSL()
    }()

    private let factory: RTCPeerConnectionFactory?
    private let rtcAudioSession: RTCAudioSession

    private var certificate: RTCCertificate?
    private var localIdentity: CallLocalMediaIdentity?
    private var iceConfiguration: CallICEConfiguration?
    private var peerConnection: RTCPeerConnection?
    private var localAudioTrack: RTCAudioTrack?
    private var audioSender: RTCRtpSender?
    private var routeObserver: NSObjectProtocol?
    private var eventContinuations: [UUID: AsyncStream<WebRTCEvent>.Continuation] = [:]
    private var lastConnectionState: CallMediaConnectionState?
    private var lastOutboundBytes: Double?
    private var lastStatsTimestamp: TimeInterval?
    private var stopped = false

    override init() {
        factory = Self.initializeSSLOnce ? RTCPeerConnectionFactory() : nil
        rtcAudioSession = RTCAudioSession.sharedInstance()
        super.init()

        // CallKit owns AVAudioSession activation. Merely creating a local
        // audio track must not start the microphone or playout audio.
        rtcAudioSession.useManualAudio = true
        rtcAudioSession.isAudioEnabled = false

        routeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: AVAudioSession.sharedInstance(),
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.emitCurrentAudioRoute()
            }
        }
    }

    deinit {
        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
        }
    }

    func prepareLocalIdentity() async throws -> CallLocalMediaIdentity {
        guard !stopped else { throw WebRTCEngineError.operationFailed }
        guard factory != nil else { throw WebRTCEngineError.frameworkUnavailable }
        if let localIdentity {
            return localIdentity
        }

        guard let generated = RTCCertificate.generate(withParams: ["name": "ECDSA"]),
              let fingerprint = generated.getFingerprints().first(where: {
                  $0.algorithm.caseInsensitiveCompare("sha-256") == .orderedSame
              }),
              let fingerprintData = Self.parseColonSeparatedFingerprint(fingerprint.value),
              fingerprintData.count == 32
        else {
            throw WebRTCEngineError.invalidFingerprint
        }

        let identity = CallLocalMediaIdentity(dtlsFingerprintSHA256: fingerprintData)
        certificate = generated
        localIdentity = identity
        return identity
    }

    func updateICEConfiguration(_ configuration: CallICEConfiguration) async throws {
        guard !stopped, certificate != nil, localIdentity != nil else {
            throw WebRTCEngineError.notPrepared
        }
        guard Self.isValid(configuration) else {
            throw WebRTCEngineError.operationFailed
        }

        // Privacy mode is fixed when a call starts. Credential renewal must
        // never be able to silently downgrade relay-only operation.
        if let existing = iceConfiguration,
           existing.transportPolicy != configuration.transportPolicy {
            throw WebRTCEngineError.operationFailed
        }

        let rtcConfiguration = try makeRTCConfiguration(from: configuration)

        if let peerConnection {
            guard peerConnection.setConfiguration(rtcConfiguration) else {
                throw WebRTCEngineError.operationFailed
            }
        } else {
            try createPeerConnection(configuration: rtcConfiguration)
        }
        iceConfiguration = configuration
    }

    func makeOffer(iceRestart: Bool) async throws -> CallSessionDescription {
        let peerConnection = try preparedPeerConnection()
        if iceRestart {
            peerConnection.restartIce()
        }

        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsIceRestart: iceRestart
                    ? kRTCMediaConstraintsValueTrue
                    : kRTCMediaConstraintsValueFalse,
            ],
            optionalConstraints: nil
        )
        let generated = try await createOffer(peerConnection, constraints: constraints)
        return try await installLocalDescription(generated, expectedType: .offer)
    }

    func makeAnswer() async throws -> CallSessionDescription {
        let peerConnection = try preparedPeerConnection()
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: [
                kRTCMediaConstraintsOfferToReceiveAudio: kRTCMediaConstraintsValueTrue,
                kRTCMediaConstraintsOfferToReceiveVideo: kRTCMediaConstraintsValueFalse,
                kRTCMediaConstraintsVoiceActivityDetection: kRTCMediaConstraintsValueTrue,
            ],
            optionalConstraints: nil
        )
        let generated = try await createAnswer(peerConnection, constraints: constraints)
        return try await installLocalDescription(generated, expectedType: .answer)
    }

    func setRemoteDescription(
        _ description: CallSessionDescription,
        expectedDTLSFingerprintSHA256: Data
    ) async throws {
        guard description.sdp.utf8.count <= Self.maximumSignaledSDPBytes,
              Self.isSafeSDPText(description.sdp) else {
            throw WebRTCEngineError.operationFailed
        }
        guard expectedDTLSFingerprintSHA256.count == 32,
              let parsedFingerprint = Self.uniqueSHA256Fingerprint(in: description.sdp),
              Self.constantTimeEqual(parsedFingerprint, expectedDTLSFingerprintSHA256)
        else {
            throw WebRTCEngineError.invalidFingerprint
        }
        guard Self.isAudioOnlySDP(description.sdp) else {
            throw WebRTCEngineError.operationFailed
        }

        let peerConnection = try preparedPeerConnection()
        let relayOnly = iceConfiguration?.transportPolicy == .relayOnly
        let safeSDP = relayOnly ? Self.removingNonRelayCandidates(from: description.sdp) : description.sdp
        let rtcDescription = RTCSessionDescription(
            type: description.type == .offer ? .offer : .answer,
            sdp: safeSDP
        )
        try await setRemote(rtcDescription, on: peerConnection)
    }

    func addRemoteICECandidate(_ candidate: CallICECandidate) async throws {
        guard candidate.candidate.utf8.count <= Self.maximumCandidateBytes,
              Self.isSafeSDPText(candidate.candidate),
              candidate.candidate.lowercased().hasPrefix("candidate:"),
              !candidate.candidate.contains("\r"),
              !candidate.candidate.contains("\n"),
              candidate.sdpMLineIndex >= 0,
              (candidate.sdpMid?.utf8.count ?? 0) <= 64
        else {
            throw WebRTCEngineError.operationFailed
        }
        if iceConfiguration?.transportPolicy == .relayOnly,
           !Self.isRelayCandidate(candidate.candidate) {
            // A fastest-route peer legitimately trickles host/srflx candidates. They are unusable
            // under this device's relay-only policy, so discard them exactly as SDP candidates are
            // discarded instead of treating the mixed privacy modes as a protocol failure.
            return
        }

        let peerConnection = try preparedPeerConnection()
        let rtcCandidate = RTCIceCandidate(
            sdp: candidate.candidate,
            sdpMLineIndex: candidate.sdpMLineIndex,
            sdpMid: candidate.sdpMid
        )
        try await add(rtcCandidate, to: peerConnection)
    }

    func setAudioSessionActive(_ active: Bool) async {
        guard !stopped else { return }
        let systemSession = AVAudioSession.sharedInstance()
        if active {
            // CallKit has already activated the system session by the time this
            // method is called. Inform WebRTC, then permit its VoIP audio unit.
            rtcAudioSession.audioSessionDidActivate(systemSession)
            rtcAudioSession.isAudioEnabled = true
            emitCurrentAudioRoute()
        } else {
            rtcAudioSession.isAudioEnabled = false
            rtcAudioSession.audioSessionDidDeactivate(systemSession)
        }
    }

    func setMuted(_ muted: Bool) async {
        guard !stopped else { return }
        localAudioTrack?.isEnabled = !muted
    }

    func setPreferredAudioRoute(_ route: CallAudioRoute) async throws {
        guard !stopped else { throw WebRTCEngineError.operationFailed }

        let systemSession = rtcAudioSession.session
        rtcAudioSession.lockForConfiguration()
        defer { rtcAudioSession.unlockForConfiguration() }

        switch route {
        case .speaker:
            try rtcAudioSession.overrideOutputAudioPort(.speaker)

        case .builtInReceiver:
            if let builtInMic = systemSession.availableInputs?.first(where: {
                $0.portType == .builtInMic
            }) {
                try rtcAudioSession.setPreferredInput(builtInMic)
            }
            try rtcAudioSession.overrideOutputAudioPort(.none)

        case .bluetooth:
            guard let input = systemSession.availableInputs?.first(where: {
                $0.portType == .bluetoothHFP || $0.portType == .bluetoothLE
            }) else {
                throw WebRTCEngineError.operationFailed
            }
            try rtcAudioSession.setPreferredInput(input)
            try rtcAudioSession.overrideOutputAudioPort(.none)

        case .wired:
            if Self.currentRoute(systemSession) != .wired,
               let input = systemSession.availableInputs?.first(where: {
                $0.portType == .headsetMic || $0.portType == .usbAudio
            }) {
                try rtcAudioSession.setPreferredInput(input)
                try rtcAudioSession.overrideOutputAudioPort(.none)
            } else if Self.currentRoute(systemSession) != .wired {
                throw WebRTCEngineError.operationFailed
            }

        case .airPlay:
            // AVAudioSession has no API to force an AirPlay output. It can be
            // selected by the system route picker; accept it only if selected.
            guard Self.currentRoute(systemSession) == .airPlay else {
                throw WebRTCEngineError.operationFailed
            }

        case .unknown:
            throw WebRTCEngineError.operationFailed
        }

        emitCurrentAudioRoute()
    }

    func statistics() async -> CallNetworkStats? {
        guard !stopped, let peerConnection else { return nil }
        let report = await withCheckedContinuation {
            (continuation: CheckedContinuation<RTCStatisticsReport, Never>) in
            peerConnection.statistics { report in
                continuation.resume(returning: report)
            }
        }
        return makeNetworkStats(from: report)
    }

    func events() async -> AsyncStream<WebRTCEvent> {
        guard !stopped else {
            return AsyncStream { continuation in continuation.finish() }
        }

        let id = UUID()
        return AsyncStream(bufferingPolicy: .bufferingNewest(64)) { continuation in
            eventContinuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.eventContinuations.removeValue(forKey: id)
                }
            }
        }
    }

    func stop() async {
        guard !stopped else { return }
        stopped = true

        rtcAudioSession.isAudioEnabled = false
        localAudioTrack?.isEnabled = false
        peerConnection?.delegate = nil
        peerConnection?.close()
        peerConnection = nil
        audioSender = nil
        localAudioTrack = nil
        iceConfiguration = nil
        localIdentity = nil
        certificate = nil
        lastOutboundBytes = nil
        lastStatsTimestamp = nil

        if let routeObserver {
            NotificationCenter.default.removeObserver(routeObserver)
            self.routeObserver = nil
        }
        eventContinuations.values.forEach { $0.finish() }
        eventContinuations.removeAll()
    }

    // MARK: - Peer creation

    private func makeRTCConfiguration(
        from configuration: CallICEConfiguration
    ) throws -> RTCConfiguration {
        guard let certificate else { throw WebRTCEngineError.notPrepared }

        let result = RTCConfiguration()
        result.iceServers = configuration.servers.map {
            RTCIceServer(
                urlStrings: $0.urls,
                username: $0.username,
                credential: $0.credential
            )
        }
        result.certificate = certificate
        result.iceTransportPolicy = configuration.transportPolicy == .relayOnly ? .relay : .all
        result.bundlePolicy = .maxBundle
        result.rtcpMuxPolicy = .require
        result.continualGatheringPolicy = .gatherContinually
        result.iceCandidatePoolSize = 1
        result.shouldPruneTurnPorts = true
        result.shouldPresumeWritableWhenFullyRelayed = configuration.transportPolicy == .relayOnly
        result.sdpSemantics = .unifiedPlan
        return result
    }

    private func createPeerConnection(configuration: RTCConfiguration) throws {
        guard let factory else { throw WebRTCEngineError.frameworkUnavailable }
        let constraints = RTCMediaConstraints(
            mandatoryConstraints: nil,
            optionalConstraints: nil
        )
        guard let peerConnection = factory.peerConnection(
            with: configuration,
            constraints: constraints,
            delegate: self
        ) else {
            throw WebRTCEngineError.operationFailed
        }

        let audioSource = factory.audioSource(with: nil)
        let audioTrack = factory.audioTrack(with: audioSource, trackId: "toj-audio")
        guard let sender = peerConnection.add(audioTrack, streamIds: ["toj-audio-stream"]) else {
            peerConnection.close()
            throw WebRTCEngineError.operationFailed
        }

        let parameters = sender.parameters
        for encoding in parameters.encodings {
            encoding.maxBitrateBps = NSNumber(value: Self.maximumAudioBitrateBps)
            encoding.networkPriority = .high
            encoding.bitratePriority = 1
            encoding.adaptiveAudioPacketTime = false
        }
        sender.parameters = parameters
        guard peerConnection.setBweMinBitrateBps(
            nil,
            currentBitrateBps: nil,
            maxBitrateBps: NSNumber(value: Self.maximumAudioBitrateBps)
        ) else {
            peerConnection.close()
            throw WebRTCEngineError.operationFailed
        }

        self.peerConnection = peerConnection
        localAudioTrack = audioTrack
        audioSender = sender
    }

    private func preparedPeerConnection() throws -> RTCPeerConnection {
        guard !stopped else { throw WebRTCEngineError.operationFailed }
        guard certificate != nil, localIdentity != nil else {
            throw WebRTCEngineError.notPrepared
        }
        guard iceConfiguration != nil, let peerConnection else {
            throw WebRTCEngineError.notPrepared
        }
        return peerConnection
    }

    private static func isValid(_ configuration: CallICEConfiguration) -> Bool {
        guard !configuration.servers.isEmpty else { return false }
        var containsAuthenticatedTURN = false

        for server in configuration.servers {
            guard !server.urls.isEmpty else { return false }
            for rawURL in server.urls {
                let scheme = rawURL.split(separator: ":", maxSplits: 1).first?.lowercased()
                guard scheme == "stun" || scheme == "stuns"
                        || scheme == "turn" || scheme == "turns"
                else { return false }

                if scheme == "turn" || scheme == "turns" {
                    guard let username = server.username, !username.isEmpty,
                          let credential = server.credential, !credential.isEmpty
                    else { return false }
                    containsAuthenticatedTURN = true
                }
            }
        }
        return containsAuthenticatedTURN
    }

    // MARK: - SDP and candidate safety

    private func installLocalDescription(
        _ generated: RTCSessionDescription,
        expectedType: CallSDPType
    ) async throws -> CallSessionDescription {
        let peerConnection = try preparedPeerConnection()
        let relayOnly = iceConfiguration?.transportPolicy == .relayOnly
        let configuredSDP = try Self.configuredAudioSDP(generated.sdp, relayOnly: relayOnly)

        guard let localIdentity,
              let actualFingerprint = Self.uniqueSHA256Fingerprint(in: configuredSDP),
              Self.constantTimeEqual(actualFingerprint, localIdentity.dtlsFingerprintSHA256)
        else {
            throw WebRTCEngineError.invalidFingerprint
        }

        let rtcType: RTCSdpType = expectedType == .offer ? .offer : .answer
        let configured = RTCSessionDescription(type: rtcType, sdp: configuredSDP)
        try await setLocal(configured, on: peerConnection)
        return CallSessionDescription(type: expectedType, sdp: configuredSDP)
    }

    private static func configuredAudioSDP(_ sdp: String, relayOnly: Bool) throws -> String {
        guard sdp.utf8.count <= maximumSignaledSDPBytes,
              isSafeSDPText(sdp),
              isAudioOnlySDP(sdp) else {
            throw WebRTCEngineError.operationFailed
        }

        var lines = normalizedLines(sdp)
        guard let mediaStart = lines.firstIndex(where: { $0.hasPrefix("m=audio ") }) else {
            throw WebRTCEngineError.operationFailed
        }
        let mediaEnd = lines[(mediaStart + 1)...].firstIndex(where: { $0.hasPrefix("m=") })
            ?? lines.endIndex

        let opusPayloads = lines[mediaStart..<mediaEnd].compactMap { line -> String? in
            guard line.lowercased().contains(" opus/48000"),
                  line.hasPrefix("a=rtpmap:")
            else { return nil }
            return line.dropFirst("a=rtpmap:".count).split(separator: " ").first.map(String.init)
        }
        guard let opusPayload = opusPayloads.first else {
            throw WebRTCEngineError.operationFailed
        }

        var mediaParts = lines[mediaStart].split(separator: " ").map(String.init)
        guard mediaParts.count >= 4 else { throw WebRTCEngineError.operationFailed }
        mediaParts = Array(mediaParts.prefix(3)) + [opusPayload]
        lines[mediaStart] = mediaParts.joined(separator: " ")

        var foundFormatParameters = false
        var foundPacketTime = false
        var foundMaximumPacketTime = false
        let existingFormatParameters = lines[mediaStart..<mediaEnd].contains {
            $0.hasPrefix("a=fmtp:\(opusPayload) ") || $0 == "a=fmtp:\(opusPayload)"
        }
        let existingPacketTime = lines[mediaStart..<mediaEnd].contains { $0.hasPrefix("a=ptime:") }
        let existingMaximumPacketTime = lines[mediaStart..<mediaEnd].contains {
            $0.hasPrefix("a=maxptime:")
        }
        var filtered: [String] = []
        filtered.reserveCapacity(lines.count + 2)

        for (index, line) in lines.enumerated() {
            let isAudioMediaLine = index >= mediaStart && index < mediaEnd
            if isAudioMediaLine, let payload = payloadIdentifier(in: line), payload != opusPayload {
                continue
            }
            if relayOnly, line.hasPrefix("a=candidate:"), !isRelayCandidate(line) {
                continue
            }

            if isAudioMediaLine,
               (line.hasPrefix("a=fmtp:\(opusPayload) ") || line == "a=fmtp:\(opusPayload)") {
                filtered.append(configuredOpusFormatLine(line, payload: opusPayload))
                foundFormatParameters = true
            } else if isAudioMediaLine, line.hasPrefix("a=ptime:") {
                filtered.append("a=ptime:20")
                foundPacketTime = true
            } else if isAudioMediaLine, line.hasPrefix("a=maxptime:") {
                filtered.append("a=maxptime:20")
                foundMaximumPacketTime = true
            } else {
                filtered.append(line)
                if isAudioMediaLine, line.hasPrefix("a=rtpmap:\(opusPayload) ") {
                    if !existingFormatParameters, !foundFormatParameters {
                        filtered.append(configuredOpusFormatLine(nil, payload: opusPayload))
                        foundFormatParameters = true
                    }
                    if !existingPacketTime, !foundPacketTime {
                        filtered.append("a=ptime:20")
                        foundPacketTime = true
                    }
                    if !existingMaximumPacketTime, !foundMaximumPacketTime {
                        filtered.append("a=maxptime:20")
                        foundMaximumPacketTime = true
                    }
                }
            }
        }

        guard foundFormatParameters, foundPacketTime, foundMaximumPacketTime else {
            throw WebRTCEngineError.operationFailed
        }
        let result = filtered.joined(separator: "\r\n") + "\r\n"
        guard result.utf8.count <= maximumSignaledSDPBytes else {
            throw WebRTCEngineError.operationFailed
        }
        return result
    }

    private static func configuredOpusFormatLine(_ line: String?, payload: String) -> String {
        var values: [String: String] = [:]
        if let line, let firstSpace = line.firstIndex(of: " ") {
            let rawParameters = line[line.index(after: firstSpace)...]
            for item in rawParameters.split(separator: ";") {
                let pair = item.split(separator: "=", maxSplits: 1).map {
                    String($0).trimmingCharacters(in: .whitespaces)
                }
                if pair.count == 2 {
                    values[pair[0].lowercased()] = pair[1]
                }
            }
        }
        values["maxaveragebitrate"] = String(maximumAudioBitrateBps)
        values["minptime"] = "20"
        values["stereo"] = "0"
        values["sprop-stereo"] = "0"
        values["useinbandfec"] = "1"
        values["usedtx"] = "1"

        let orderedKeys = [
            "minptime", "maxaveragebitrate", "useinbandfec", "usedtx", "stereo", "sprop-stereo",
        ]
        let known = orderedKeys.compactMap { key in values[key].map { "\(key)=\($0)" } }
        let remaining = values.keys.filter { !orderedKeys.contains($0) }.sorted().compactMap { key in
            values[key].map { "\(key)=\($0)" }
        }
        return "a=fmtp:\(payload) " + (known + remaining).joined(separator: ";")
    }

    private static func payloadIdentifier(in line: String) -> String? {
        let prefixes = ["a=rtpmap:", "a=fmtp:", "a=rtcp-fb:"]
        guard let prefix = prefixes.first(where: { line.hasPrefix($0) }) else { return nil }
        return line.dropFirst(prefix.count).split(whereSeparator: { $0 == " " || $0 == "\t" }).first
            .map(String.init)
    }

    private static func isAudioOnlySDP(_ sdp: String) -> Bool {
        var activeMediaSections = 0
        var audioPayloads: Set<String> = []
        var hasOpus = false
        for line in normalizedLines(sdp) {
            if line.hasPrefix("m=") {
                let fields = line.split(separator: " ")
                guard fields.count >= 4 else { return false }
                let kind = fields[0].dropFirst(2).lowercased()
                let port = fields[1].split(separator: "/").first.flatMap { Int($0) }
                guard kind == "audio", port != nil, port != 0 else { return false }
                audioPayloads = Set(fields.dropFirst(3).map(String.init))
                activeMediaSections += 1
            }
            if line.lowercased().hasPrefix("a=rtpmap:"),
               line.lowercased().contains(" opus/48000") {
                let payload = line.dropFirst("a=rtpmap:".count).split(separator: " ").first
                    .map(String.init)
                if payload.map(audioPayloads.contains) == true {
                    hasOpus = true
                }
            }
        }
        return activeMediaSections == 1 && hasOpus
    }

    private static func uniqueSHA256Fingerprint(in sdp: String) -> Data? {
        var result: Data?
        for line in normalizedLines(sdp) where line.lowercased().hasPrefix("a=fingerprint:") {
            let value = line.dropFirst("a=fingerprint:".count)
            let fields = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, fields[0].lowercased() == "sha-256",
                  let parsed = parseColonSeparatedFingerprint(String(fields[1])),
                  parsed.count == 32
            else { return nil }
            if let result, !constantTimeEqual(result, parsed) {
                return nil
            }
            result = parsed
        }
        return result
    }

    private static func parseColonSeparatedFingerprint(_ value: String) -> Data? {
        let octets = value.split(separator: ":", omittingEmptySubsequences: false)
        guard octets.count == 32 else { return nil }
        var result = Data()
        result.reserveCapacity(32)
        for octet in octets {
            guard octet.count == 2, let byte = UInt8(octet, radix: 16) else { return nil }
            result.append(byte)
        }
        return result
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else { return false }
        var difference: UInt8 = 0
        for (left, right) in zip(lhs, rhs) {
            difference |= left ^ right
        }
        return difference == 0
    }

    private static func removingNonRelayCandidates(from sdp: String) -> String {
        normalizedLines(sdp).filter {
            !$0.hasPrefix("a=candidate:") || isRelayCandidate($0)
        }.joined(separator: "\r\n") + "\r\n"
    }

    private static func isRelayCandidate(_ candidate: String) -> Bool {
        CallICECandidatePolicy.isRelay(candidate)
    }

    private static func normalizedLines(_ sdp: String) -> [String] {
        sdp.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    private static func isSafeSDPText(_ sdp: String) -> Bool {
        sdp.unicodeScalars.allSatisfy { scalar in
            scalar.value == 0x09 || scalar.value == 0x0A || scalar.value == 0x0D
                || (0x20...0x7E).contains(scalar.value)
        }
    }

    // MARK: - WebRTC completion bridging

    private func createOffer(
        _ peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.offer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WebRTCEngineError.operationFailed)
                }
            }
        }
    }

    private func createAnswer(
        _ peerConnection: RTCPeerConnection,
        constraints: RTCMediaConstraints
    ) async throws -> RTCSessionDescription {
        try await withCheckedThrowingContinuation { continuation in
            peerConnection.answer(for: constraints) { description, error in
                if let error {
                    continuation.resume(throwing: error)
                } else if let description {
                    continuation.resume(returning: description)
                } else {
                    continuation.resume(throwing: WebRTCEngineError.operationFailed)
                }
            }
        }
    }

    private func setLocal(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setLocalDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func setRemote(
        _ description: RTCSessionDescription,
        on peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.setRemoteDescription(description) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    private func add(
        _ candidate: RTCIceCandidate,
        to peerConnection: RTCPeerConnection
    ) async throws {
        try await withCheckedThrowingContinuation {
            (continuation: CheckedContinuation<Void, Error>) in
            peerConnection.add(candidate) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume(returning: ())
                }
            }
        }
    }

    // MARK: - Events and stats

    private func emit(_ event: WebRTCEvent) {
        for continuation in eventContinuations.values {
            continuation.yield(event)
        }
    }

    private func emitConnectionState(_ state: CallMediaConnectionState) {
        guard lastConnectionState != state else { return }
        lastConnectionState = state
        emit(.connectionStateChanged(state))
    }

    private func emitCurrentAudioRoute() {
        emit(.audioRouteChanged(Self.currentRoute(rtcAudioSession.session)))
    }

    private static func currentRoute(_ session: AVAudioSession) -> CallAudioRoute {
        let outputs = session.currentRoute.outputs
        if outputs.contains(where: { $0.portType == .builtInSpeaker }) { return .speaker }
        if outputs.contains(where: { $0.portType == .builtInReceiver }) { return .builtInReceiver }
        if outputs.contains(where: {
            $0.portType == .bluetoothA2DP || $0.portType == .bluetoothHFP
                || $0.portType == .bluetoothLE
        }) { return .bluetooth }
        if outputs.contains(where: { $0.portType == .airPlay }) { return .airPlay }
        if outputs.contains(where: {
            $0.portType == .headphones || $0.portType == .headsetMic
                || $0.portType == .usbAudio || $0.portType == .lineOut
        }) { return .wired }
        return .unknown
    }

    private func makeNetworkStats(from report: RTCStatisticsReport) -> CallNetworkStats {
        let statistics = Array(report.statistics.values)
        let candidatePairs = statistics.filter { $0.type == "candidate-pair" }
        let selectedPair = candidatePairs.first(where: {
            Self.bool($0.values["selected"]) == true
        }) ?? candidatePairs.first(where: {
            Self.bool($0.values["nominated"]) == true
                && Self.string($0.values["state"]) == "succeeded"
        })

        let inboundAudio = statistics.filter {
            $0.type == "inbound-rtp" && Self.isAudioStats($0.values)
        }
        let outboundAudio = statistics.filter {
            $0.type == "outbound-rtp" && Self.isAudioStats($0.values)
        }
        let remoteInboundAudio = statistics.filter {
            $0.type == "remote-inbound-rtp" && Self.isAudioStats($0.values)
        }

        let packetsLost = inboundAudio.compactMap { Self.int64($0.values["packetsLost"]) }.reduce(0, +)
        let packetsReceived = inboundAudio.compactMap {
            Self.int64($0.values["packetsReceived"])
        }.reduce(0, +)
        let jitterSeconds = inboundAudio.compactMap { Self.double($0.values["jitter"]) }.max()
        let roundTripSeconds = Self.double(selectedPair?.values["currentRoundTripTime"])
            ?? remoteInboundAudio.compactMap { Self.double($0.values["roundTripTime"]) }.max()
        let totalOutboundBytes = outboundAudio.compactMap {
            Self.double($0.values["bytesSent"])
        }.reduce(0, +)

        let now = ProcessInfo.processInfo.systemUptime
        var audioBitrate: Double?
        if let previousBytes = lastOutboundBytes, let previousTime = lastStatsTimestamp,
           totalOutboundBytes >= previousBytes, now > previousTime {
            audioBitrate = (totalOutboundBytes - previousBytes) * 8 / (now - previousTime)
        }
        lastOutboundBytes = totalOutboundBytes
        lastStatsTimestamp = now

        return CallNetworkStats(
            roundTripTimeMilliseconds: roundTripSeconds.map { $0 * 1_000 },
            jitterMilliseconds: jitterSeconds.map { $0 * 1_000 },
            packetsLost: inboundAudio.isEmpty ? nil : packetsLost,
            packetsReceived: inboundAudio.isEmpty ? nil : packetsReceived,
            availableOutgoingBitrate: Self.double(selectedPair?.values["availableOutgoingBitrate"]),
            audioBitrate: audioBitrate
        )
    }

    private static func isAudioStats(_ values: [String: NSObject]) -> Bool {
        string(values["kind"]) == "audio" || string(values["mediaType"]) == "audio"
    }

    private static func string(_ value: NSObject?) -> String? {
        (value as? NSString).map(String.init)
    }

    private static func double(_ value: NSObject?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }

    private static func int64(_ value: NSObject?) -> Int64? {
        (value as? NSNumber)?.int64Value
    }

    private static func bool(_ value: NSObject?) -> Bool? {
        (value as? NSNumber)?.boolValue
    }
}

extension WebRTCVoiceEngine: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange stateChanged: RTCSignalingState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didAdd stream: RTCMediaStream
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove stream: RTCMediaStream
    ) {}

    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceConnectionState
    ) {
        let mapped: CallMediaConnectionState
        switch newState {
        case .new: mapped = .new
        case .checking: mapped = .checking
        case .connected, .completed: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed, .count: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .failed
        }
        Task { @MainActor [weak self] in self?.emitConnectionState(mapped) }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCIceGatheringState
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didGenerate candidate: RTCIceCandidate
    ) {
        let signaled = CallICECandidate(
            sdpMid: candidate.sdpMid,
            sdpMLineIndex: candidate.sdpMLineIndex,
            candidate: candidate.sdp
        )
        Task { @MainActor [weak self] in
            guard let self, !self.stopped else { return }
            if self.iceConfiguration?.transportPolicy == .relayOnly,
               !Self.isRelayCandidate(signaled.candidate) {
                return
            }
            self.emit(.localCandidate(signaled))
        }
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didRemove candidates: [RTCIceCandidate]
    ) {}

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didOpen dataChannel: RTCDataChannel
    ) {
        // Toj voice calls have no data channels. A negotiated channel is not
        // used and is closed with the peer connection.
    }

    nonisolated func peerConnection(
        _ peerConnection: RTCPeerConnection,
        didChange newState: RTCPeerConnectionState
    ) {
        let mapped: CallMediaConnectionState
        switch newState {
        case .new: mapped = .new
        case .connecting: mapped = .checking
        case .connected: mapped = .connected
        case .disconnected: mapped = .disconnected
        case .failed: mapped = .failed
        case .closed: mapped = .closed
        @unknown default: mapped = .failed
        }
        Task { @MainActor [weak self] in self?.emitConnectionState(mapped) }
    }
}

#endif
