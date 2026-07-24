@preconcurrency import AVFoundation
@preconcurrency import CallKit
import Foundation
@preconcurrency import ObjectiveC
import UIKit

nonisolated struct CallAudioRouteOption: Identifiable, Equatable, Sendable {
    let id: String
    let name: String
    let portType: String
}

protocol CallAudioSessionControlling: AnyObject {
    var onRouteChanged: (() -> Void)? { get set }
    var onMediaServicesReset: (() -> Void)? { get set }
    func setVideoMode(_ enabled: Bool) throws
    func setSpeakerEnabled(_ enabled: Bool) throws
    var isSpeakerEnabled: Bool { get }
    var currentRouteName: String { get }
    var currentRoute: CallAudioRoute { get }
}

protocol CallKitControlling: AnyObject {
    var onStart: ((UUID) -> Void)? { get set }
    var onAnswer: ((UUID) async -> Bool)? { get set }
    var onEnd: ((UUID) -> Void)? { get set }
    var onMuteChanged: ((UUID, Bool) -> Void)? { get set }
    var onAudioActivated: (() -> Void)? { get set }
    var onAudioDeactivated: (() -> Void)? { get set }
    var onReset: (() -> Void)? { get set }
    var callAudioSession: any CallAudioSessionControlling { get }

    func reportIncoming(
        callId: UUID,
        callerAccountId: String,
        displayName: String,
        initialKind: CallInitialKind
    ) async throws
    func requestOutgoing(
        callId: UUID,
        peerAccountId: String,
        displayName: String,
        initialKind: CallInitialKind
    ) async throws
    func requestEnd(callId: UUID) async throws
    func requestMute(callId: UUID, muted: Bool) async throws
    func reportOutgoingConnecting(callId: UUID)
    func reportOutgoingConnected(callId: UUID)
    func reportEnded(callId: UUID, reason: CXCallEndedReason)
    func updateHasVideo(callId: UUID, hasVideo: Bool)
}

protocol CallPermissionProviding: AnyObject {
    var microphonePermissionDenied: Bool { get }
    func microphoneAllowed() async -> Bool
    var cameraPermission: CallCameraPermissionState { get }
    func requestCameraAccess() async -> Bool
}

protocol CallSceneLifecycleProviding: AnyObject {
    var isForeground: Bool { get }
    func isForeground(sceneIdentifier: String) -> Bool
}

protocol CallNetworkPathProviding: AnyObject, Sendable {
    func snapshot() -> ReplicaNetworkSnapshot
}

protocol CallClock: Sendable {
    var now: Date { get }
    var uptime: TimeInterval { get }
    func sleep(for duration: Duration) async throws
}

struct SystemCallClock: CallClock {
    var now: Date { Date() }
    var uptime: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func sleep(for duration: Duration) async throws {
        try await ContinuousClock().sleep(for: duration)
    }
}

@MainActor
final class SystemCallPermissionProvider: CallPermissionProviding {
    var microphonePermissionDenied: Bool {
        AVAudioApplication.shared.recordPermission == .denied
    }

    func microphoneAllowed() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted: return true
        case .denied: return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) }
            }
        @unknown default: return false
        }
    }

    var cameraPermission: CallCameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: .authorized
        case .denied: .denied
        case .restricted: .restricted
        case .notDetermined: .notDetermined
        @unknown default: .denied
        }
    }

    func requestCameraAccess() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .video)
    }
}

@MainActor
final class SystemCallSceneLifecycleProvider: CallSceneLifecycleProviding {
    var isForeground: Bool { UIApplication.shared.applicationState == .active }

    func isForeground(sceneIdentifier: String) -> Bool {
        UIApplication.shared.connectedScenes.contains { scene in
            scene.session.persistentIdentifier == sceneIdentifier
                && scene.activationState == .foregroundActive
        }
    }
}

extension ReplicaNetworkMonitor: CallNetworkPathProviding {}

nonisolated enum CallKitVideoContract {
    static func immutableStartActionIsVideo(for initialKind: CallInitialKind) -> Bool {
        initialKind == .video
    }

    static func initialUpdateHasVideo(for initialKind: CallInitialKind) -> Bool {
        initialKind == .video
    }

    static func shouldAutoEnableSpeaker(for route: CallAudioRoute) -> Bool {
        route == .builtInReceiver || route == .unknown
    }
}

@MainActor
final class CallAudioSessionController: CallAudioSessionControlling {
    private let session: AVAudioSession
    private var observers: [NSObjectProtocol] = []

    var onRouteChanged: (() -> Void)?
    var onInterrupted: ((_ began: Bool) -> Void)?
    var onMediaServicesReset: (() -> Void)?

    init(session: AVAudioSession = .sharedInstance()) {
        self.session = session
        let center = NotificationCenter.default
        observers = [
            center.addObserver(
                forName: AVAudioSession.routeChangeNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onRouteChanged?() }
            },
            center.addObserver(
                forName: AVAudioSession.interruptionNotification,
                object: session,
                queue: .main
            ) { [weak self] notification in
                let raw = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                let began = raw.flatMap(AVAudioSession.InterruptionType.init(rawValue:)) == .began
                Task { @MainActor in self?.onInterrupted?(began) }
            },
            center.addObserver(
                forName: AVAudioSession.mediaServicesWereResetNotification,
                object: session,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.onMediaServicesReset?() }
            },
        ]
    }

    func prepareForCall(videoEnabled: Bool) throws {
        try session.setCategory(
            .playAndRecord,
            mode: videoEnabled ? .videoChat : .voiceChat,
            options: [.allowBluetoothHFP, .allowAirPlay]
        )
    }

    func setVideoMode(_ enabled: Bool) throws {
        try session.setMode(enabled ? .videoChat : .voiceChat)
    }

    /// CallKit owns activation. The media engine starts audio only after this callback.
    func didActivate() {
        onRouteChanged?()
    }

    func setSpeakerEnabled(_ enabled: Bool) throws {
        try session.overrideOutputAudioPort(enabled ? .speaker : .none)
        onRouteChanged?()
    }

    var isSpeakerEnabled: Bool {
        session.currentRoute.outputs.contains { $0.portType == .builtInSpeaker }
    }

    var currentRouteName: String {
        session.currentRoute.outputs.first?.portName ?? String(localized: "iPhone")
    }

    var currentRoute: CallAudioRoute {
        let types = session.currentRoute.outputs.map(\.portType)
        if types.contains(.builtInSpeaker) { return .speaker }
        if types.contains(.builtInReceiver) { return .builtInReceiver }
        if types.contains(where: { [.bluetoothA2DP, .bluetoothHFP, .bluetoothLE].contains($0) }) {
            return .bluetooth
        }
        if types.contains(.airPlay) { return .airPlay }
        if types.contains(where: { [.headphones, .headsetMic, .usbAudio, .lineOut].contains($0) }) {
            return .wired
        }
        return .unknown
    }

    var availableInputs: [CallAudioRouteOption] {
        (session.availableInputs ?? []).map {
            CallAudioRouteOption(id: $0.uid, name: $0.portName, portType: $0.portType.rawValue)
        }
    }

    func selectInput(id: String?) throws {
        let input = id.flatMap { id in session.availableInputs?.first(where: { $0.uid == id }) }
        try session.setPreferredInput(input)
        if input != nil {
            try session.overrideOutputAudioPort(.none)
        }
        onRouteChanged?()
    }
}

@MainActor
final class CallKitAdapter: NSObject, CallKitControlling {
    static let shared = CallKitAdapter()

    var onStart: ((UUID) -> Void)?
    var onAnswer: ((UUID) async -> Bool)?
    var onEnd: ((UUID) -> Void)?
    var onMuteChanged: ((UUID, Bool) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onReset: (() -> Void)?

    let audioSession: CallAudioSessionController
    var callAudioSession: any CallAudioSessionControlling { audioSession }
    private let provider: CXProvider
    private let callController: CXCallController
    private var pendingAnswerTasks: [UUID: Task<Bool, Never>] = [:]
    private var initialKinds: [UUID: CallInitialKind] = [:]

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = true
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        configuration.supportedHandleTypes = [.generic]
        configuration.includesCallsInRecents = false
        if let icon = UIImage(named: "AppIcon")?.pngData() {
            configuration.iconTemplateImageData = icon
        }
        provider = CXProvider(configuration: configuration)
        callController = CXCallController(queue: .main)
        audioSession = CallAudioSessionController()
        super.init()
        provider.setDelegate(self, queue: .main)
    }

    func reportIncoming(
        callId: UUID,
        callerAccountId: String,
        displayName: String,
        initialKind: CallInitialKind
    ) async throws {
        initialKinds[callId] = initialKind
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerAccountId)
        update.localizedCallerName = displayName
        update.hasVideo = CallKitVideoContract.initialUpdateHasVideo(for: initialKind)
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                provider.reportNewIncomingCall(with: callId, update: update) { error in
                    if let error {
                        continuation.resume(throwing: error)
                    } else {
                        continuation.resume()
                    }
                }
            }
        } catch {
            initialKinds.removeValue(forKey: callId)
            throw error
        }
    }

    func requestOutgoing(
        callId: UUID,
        peerAccountId: String,
        displayName: String,
        initialKind: CallInitialKind
    ) async throws {
        initialKinds[callId] = initialKind
        let action = CXStartCallAction(
            call: callId,
            handle: CXHandle(type: .generic, value: peerAccountId)
        )
        action.isVideo = CallKitVideoContract.immutableStartActionIsVideo(for: initialKind)
        do {
            try await request(CXTransaction(action: action))
        } catch {
            initialKinds.removeValue(forKey: callId)
            throw error
        }

        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.localizedCallerName = displayName
        update.hasVideo = CallKitVideoContract.initialUpdateHasVideo(for: initialKind)
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        provider.reportCall(with: callId, updated: update)
    }

    func requestEnd(callId: UUID) async throws {
        try await request(CXTransaction(action: CXEndCallAction(call: callId)))
    }

    func requestMute(callId: UUID, muted: Bool) async throws {
        try await request(CXTransaction(action: CXSetMutedCallAction(call: callId, muted: muted)))
    }

    func reportOutgoingConnecting(callId: UUID) {
        provider.reportOutgoingCall(with: callId, startedConnectingAt: nil)
    }

    func reportOutgoingConnected(callId: UUID) {
        provider.reportOutgoingCall(with: callId, connectedAt: nil)
    }

    func reportEnded(callId: UUID, reason: CXCallEndedReason) {
        initialKinds.removeValue(forKey: callId)
        provider.reportCall(with: callId, endedAt: Date(), reason: reason)
    }

    func updateHasVideo(callId: UUID, hasVideo: Bool) {
        let update = CXCallUpdate()
        update.hasVideo = hasVideo
        provider.reportCall(with: callId, updated: update)
    }

    private func request(_ transaction: CXTransaction) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            callController.request(transaction) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }
}

extension CallKitAdapter: CXProviderDelegate {
    nonisolated func providerDidReset(_ provider: CXProvider) {
        Task { @MainActor in
            for task in pendingAnswerTasks.values { task.cancel() }
            pendingAnswerTasks.removeAll()
            initialKinds.removeAll()
            onReset?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            do {
                try audioSession.prepareForCall(videoEnabled: action.isVideo)
                if action.isVideo,
                   CallKitVideoContract.shouldAutoEnableSpeaker(for: audioSession.currentRoute) {
                    try audioSession.setSpeakerEnabled(true)
                }
                onStart?(action.callUUID)
                action.fulfill()
            } catch {
                initialKinds.removeValue(forKey: action.callUUID)
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            do {
                let isVideo = initialKinds[action.callUUID] == .video
                try audioSession.prepareForCall(videoEnabled: isVideo)
                if isVideo,
                   CallKitVideoContract.shouldAutoEnableSpeaker(for: audioSession.currentRoute) {
                    try audioSession.setSpeakerEnabled(true)
                }
                let work = Task { @MainActor [weak self] in
                    await self?.onAnswer?(action.callUUID) ?? false
                }
                pendingAnswerTasks[action.callUUID] = work
                // CallKit actions must be acknowledged promptly. Secure negotiation continues in
                // the tracked task; a failure immediately ends the fulfilled system call.
                action.fulfill()
                let answered = await work.value
                guard pendingAnswerTasks.removeValue(forKey: action.callUUID) != nil else { return }
                if !answered {
                    initialKinds.removeValue(forKey: action.callUUID)
                    provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                }
            } catch {
                initialKinds.removeValue(forKey: action.callUUID)
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, timedOutPerforming action: CXAction) {
        Task { @MainActor in
            if let answer = action as? CXAnswerCallAction,
               let work = pendingAnswerTasks.removeValue(forKey: answer.callUUID) {
                work.cancel()
                onEnd?(answer.callUUID)
            }
            if action is CXStartCallAction || action is CXAnswerCallAction || action is CXEndCallAction,
               let callAction = action as? CXCallAction {
                initialKinds.removeValue(forKey: callAction.callUUID)
            }
            action.fail()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            pendingAnswerTasks.removeValue(forKey: action.callUUID)?.cancel()
            initialKinds.removeValue(forKey: action.callUUID)
            onEnd?(action.callUUID)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        Task { @MainActor in
            onMuteChanged?(action.callUUID, action.isMuted)
            action.fulfill()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        Task { @MainActor in
            self.audioSession.didActivate()
            onAudioActivated?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        Task { @MainActor in onAudioDeactivated?() }
    }
}
