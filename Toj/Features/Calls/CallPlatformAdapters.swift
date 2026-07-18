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

@MainActor
final class CallAudioSessionController {
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

    func prepareForCall() throws {
        try session.setCategory(
            .playAndRecord,
            mode: .voiceChat,
            options: [.allowBluetoothHFP, .allowAirPlay]
        )
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
final class CallKitAdapter: NSObject {
    static let shared = CallKitAdapter()

    var onStart: ((UUID) -> Void)?
    var onAnswer: ((UUID) async -> Bool)?
    var onEnd: ((UUID) -> Void)?
    var onMuteChanged: ((UUID, Bool) -> Void)?
    var onAudioActivated: (() -> Void)?
    var onAudioDeactivated: (() -> Void)?
    var onReset: (() -> Void)?

    let audioSession: CallAudioSessionController
    private let provider: CXProvider
    private let callController: CXCallController
    private var pendingAnswerTasks: [UUID: Task<Bool, Never>] = [:]

    override init() {
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
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

    func reportIncoming(callId: UUID, callerAccountId: String, displayName: String) async throws {
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: callerAccountId)
        update.localizedCallerName = displayName
        update.hasVideo = false
        update.supportsDTMF = false
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false

        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            provider.reportNewIncomingCall(with: callId, update: update) { error in
                if let error {
                    continuation.resume(throwing: error)
                } else {
                    continuation.resume()
                }
            }
        }
    }

    func requestOutgoing(callId: UUID, peerAccountId: String, displayName: String) async throws {
        let action = CXStartCallAction(
            call: callId,
            handle: CXHandle(type: .generic, value: peerAccountId)
        )
        action.isVideo = false
        try await request(CXTransaction(action: action))

        let update = CXCallUpdate()
        update.remoteHandle = action.handle
        update.localizedCallerName = displayName
        update.hasVideo = false
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
        provider.reportCall(with: callId, endedAt: Date(), reason: reason)
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
            onReset?()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXStartCallAction) {
        Task { @MainActor in
            do {
                try audioSession.prepareForCall()
                onStart?(action.callUUID)
                action.fulfill()
            } catch {
                action.fail()
            }
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        Task { @MainActor in
            do {
                try audioSession.prepareForCall()
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
                    provider.reportCall(with: action.callUUID, endedAt: Date(), reason: .failed)
                }
            } catch {
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
            action.fail()
        }
    }

    nonisolated func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        Task { @MainActor in
            pendingAnswerTasks.removeValue(forKey: action.callUUID)?.cancel()
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
