import Foundation
import Observation
import UIKit

nonisolated enum ReplicaConnectivityState: Equatable, Sendable {
    case unknown
    case checking
    case reachable
    case offline
    case serverUnavailable
    case sessionExpired
    case configurationError
}

nonisolated enum ReplicaSyncFailureReason: Equatable, Sendable {
    case slowConnection
    case serverUnavailable
    case protocolFailure
    case localReplicaFailure
    case configuration
}

nonisolated enum ReplicaUpdatePhase: Equatable, Sendable {
    case idle
    case checkingRemoteState
    case catchingUp(appliedBatches: Int)
    case upToDate
    case stalled(reason: ReplicaSyncFailureReason)
}

nonisolated struct ReplicaSyncSnapshot: Equatable, Sendable {
    let connectivity: ReplicaConnectivityState
    let updatePhase: ReplicaUpdatePhase
    let lastSuccessfulServerContact: Date?
}

nonisolated enum ReplicaSyncState: Equatable, Sendable {
    case checking
    case updating
    case ready
    case offline
    case connectionSlow
    case serverUnavailable
    case sessionExpired
    case protocolFailure
    case localFailure
    case configurationError

    var title: String {
        switch self {
        case .checking: String(localized: "Checking connection…")
        case .updating: String(localized: "Updating chats…")
        case .ready: String(localized: "Chats are up to date")
        case .offline: String(localized: "Offline — showing saved chats")
        case .connectionSlow: String(localized: "Connection is slow — showing saved chats")
        case .serverUnavailable: String(localized: "Server unavailable — showing saved chats")
        case .sessionExpired: String(localized: "Session expired — saved chats remain available")
        case .protocolFailure: String(localized: "Update could not be read — showing saved chats")
        case .localFailure: String(localized: "Saved chats need repair")
        case .configurationError: String(localized: "Server configuration needs attention")
        }
    }

    var systemImage: String {
        switch self {
        case .checking: "network"
        case .updating: "arrow.triangle.2.circlepath"
        case .ready: "checkmark.circle.fill"
        case .offline: "wifi.slash"
        case .connectionSlow: "hourglass"
        case .serverUnavailable: "exclamationmark.icloud"
        case .sessionExpired: "person.crop.circle.badge.exclamationmark"
        case .protocolFailure: "exclamationmark.triangle"
        case .localFailure: "externaldrive.badge.exclamationmark"
        case .configurationError: "gear.badge.xmark"
        }
    }

    var showsProgress: Bool { self == .checking || self == .updating }
    var showsRetry: Bool {
        switch self {
        case .offline, .connectionSlow, .serverUnavailable, .protocolFailure, .localFailure:
            true
        case .checking, .updating, .ready, .sessionExpired, .configurationError:
            false
        }
    }
}

nonisolated enum ConversationOpenState: Equatable, Sendable {
    case cached
    case loadingLocal
    case ready
    case empty
    case failedLocal
}

nonisolated private enum ReplicaStateProbeOutcome: Sendable {
    case succeeded(SyncStateResponse)
    case failed(ReplicaSyncState)
    case timedOut
    case cancelled
}

@MainActor
@Observable
final class CloudAppModel {
    static let shared = CloudAppModel()
    nonisolated static let foregroundSyncTimeoutSeconds: TimeInterval = 15

    struct ContactIdentity: Equatable, Sendable {
        let accountId: String
        let displayName: String
        let bio: String?
        let birthday: String?
        let colorIndex: Int?

        init(
            accountId: String,
            displayName: String,
            bio: String? = nil,
            birthday: String? = nil,
            colorIndex: Int? = nil
        ) {
            self.accountId = accountId
            self.displayName = displayName
            self.bio = bio
            self.birthday = birthday
            self.colorIndex = colorIndex
        }
    }

    struct Notice: Identifiable, Equatable {
        let id = UUID()
        let title: String
        let message: String
        var opensSettings = false

        static func == (lhs: Notice, rhs: Notice) -> Bool {
            lhs.id == rhs.id
        }
    }

    struct Dialog: Identifiable, Equatable {
        let id: String
        let title: String
        var subtitle: String
        var updatedAt: String
        var isPending: Bool
        var unreadCount: Int
        var draftPreview: String? = nil
        var isPinned = false
        var isMuted = false
        var isArchived = false
        var mentionCount = 0
        var isTyping = false
        var previewKind: ChatListPreviewKind = .text
        var lastMessageMine = false
        var peerAccountId: String? = nil
        var peerBio: String? = nil
        var peerBirthday: String? = nil
        var profileColorIndex: Int? = nil
    }

    struct Line: Identifiable, Equatable, Sendable {
        enum Delivery: Equatable, Sendable {
            case sending
            case sent
            case seen
            case failed(String)
        }

        enum TransferStage: Equatable, Sendable {
            case preparing
            case uploading
            case finalizing
            case retrying
        }

        let id: String
        var dialogId: String?
        var msgId: Int64?
        var clientMsgId: String
        var senderAccountId: String? = nil
        var text: String
        var mine: Bool
        var delivery: Delivery
        var timestamp: String?
        var replyToMsgId: Int64? = nil
        var replyPreview: String? = nil
        var reactions: [String] = []
        var myReaction: String? = nil
        var forwardedFromAccountId: String? = nil
        var forwardedFromDialogId: String? = nil
        var forwardedFromMsgId: Int64? = nil
        var isForwarded = false
        var editVersion = 0
        var isEdited = false
        var isDeleted = false
        var attachment: DemoAttachment? = nil
        var media: CloudMedia? = nil
        var transferProgress: Double? = nil
        var transferStage: TransferStage? = nil
        var transferError: String? = nil
        var pendingMutation: PendingMessageMutation? = nil
        var presentationDayLabel: String? = nil
        var presentationTimestampLabel: String? = nil
        var presentationMediaTimestampLabel: String? = nil
        var presentationIsFirstInGroup = true
        var presentationIsLastInGroup = true
    }

    private(set) var storedSession: StoredCloudSession?
    private(set) var launchPhase: LaunchPhase = .restoringLocal
    private(set) var status = "Starting"
    private(set) var operationNotice: Notice?
    private(set) var connectionViewState: ReplicaConnectionState = .connecting
    private(set) var replicaSyncState: ReplicaSyncState = .checking
    private(set) var replicaConnectivityState: ReplicaConnectivityState = .unknown
    private(set) var replicaUpdatePhase: ReplicaUpdatePhase = .idle
    private(set) var lastSuccessfulServerContact: Date?
    private(set) var requestedCode = false
    private(set) var authRequestInFlight = false
    private(set) var authVerifyInFlight = false
    private(set) var resendSeconds = 0
    private(set) var activeDialogId: String?
    private(set) var conversationOpenState: ConversationOpenState = .loadingLocal
    private(set) var dialogs: [Dialog] = []
    private(set) var lines: [Line] = []
    private(set) var openingTimelineAnchor: TimelineAnchor = .bottom
    private(set) var canLoadEarlier = false
    private(set) var loadingEarlier = false
    private(set) var canLoadLater = false
    private(set) var loadingLater = false
    private(set) var devices: [CloudDevice] = []
    private(set) var loadingDevices = false
    private(set) var accountDeletionRequested = false
    private(set) var accountDeletionInFlight = false
    private(set) var mediaCacheBytes: Int64 = 0
    private(set) var mediaAutoDownloadPolicy: MediaAutoDownloadPolicy = .default
    private(set) var mediaCachePolicy: MediaCachePolicy = .default
    private(set) var clearingMediaCache = false
    private(set) var composerMode: ComposerMode = .text
    private(set) var profileDetails: StoredProfileDetails = .empty
    private(set) var profileSaveInFlight = false
    #if DEBUG
    private(set) var isDemoMode = false
    #endif

    var phone = "+992 "
    var displayName = ""
    var code = ""
    var peerPhone = ""
    var draft = "" {
        didSet {
            guard let activeDialogId else { return }
            draftsByDialog[activeDialogId] = draft
            if let index = dialogs.firstIndex(where: { $0.id == activeDialogId }) {
                let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                dialogs[index].draftPreview = trimmed.isEmpty ? nil : trimmed
            }
        }
    }
    var accountDeletionCode = ""

    private let api: CloudAPI
    private let tokenStore: TokenStore
    private var localStore: CloudLocalStore?
    private let localStoreBootstrapper = CloudLocalStoreBootstrapper()
    private let opensDefaultLocalStore: Bool
    private let pushCenter: PushRegistrationCenter
    private let mediaEngine: CloudMediaTransferEngine
    private let capabilityDefaults: UserDefaults
    private let capabilityCacheKey: String
    private var negotiatedCapabilities: MessagingCapabilities
    @ObservationIgnored private lazy var mediaPrefetchScheduler = MediaPrefetchScheduler { [weak self] lane in
        guard let self else { return false }
        return await self.processOneMediaDownload(component: lane.component)
    }
    @ObservationIgnored private lazy var replicaSyncCoordinator = ReplicaSyncCoordinator { [weak self] generation in
        guard let self else { return }
        await self.runForegroundSyncAttempt(generation: generation)
    }
    private let voiceRecorder = VoiceNoteRecorder()
    private var pts: Int64 = 0
    private var hintSocket: CloudHintSocket?
    private var hintTask: Task<Void, Never>?
    private var networkObservationTask: Task<Void, Never>?
    private var memoryPressureTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var resendTask: Task<Void, Never>?
    private var recordingTask: Task<Void, Never>?
    private var composerMediaTask: Task<Void, Never>?
    private var profileSyncTask: Task<Void, Never>?
    private var profilePhotoMigrationTask: Task<Void, Never>?
    private var postSignInTask: Task<Void, Never>?
    private var postSyncWorkTask: Task<Void, Never>?
    private var historyHydrationTask: Task<Void, Never>?
    private var openingAnchorHydrationTask: Task<Void, Never>?
    private var dialogObservationTask: Task<Void, Never>?
    private var timelineObservationTask: Task<Void, Never>?
    private var viewportPersistenceTask: Task<Void, Never>?
    private var mediaDownloadTask: Task<Void, Never>?
    private var readReceiptRetryTask: Task<Void, Never>?
    private var replicaIntegrityTask: Task<Void, Never>?
    private var localRestoreTask: Task<Void, Never>?
    private var localRestoreCompleted = false
    private var backgroundMediaRuntimePrepared = false
    private var mediaSchedulerForegrounded = false
    private var composerMediaOperationId: UUID?
    private var activeComposerTransferId: String?
    private var mediaTransferTasks: [String: Task<Void, Never>] = [:]
    private var syncInFlight = false
    private var syncAgain = false
    private var retryInFlight = false
    private var mediaTransfersInFlight: Set<String> = []
    private var messageMutationsInFlight: Set<String> = []
    private var mutationTargetsBeingQueued: Set<String> = []
    private var uploadedPushRegistration: String?
    private var historyHasMoreByDialog: [String: Bool] = [:]
    private var draftsByDialog: [String: String] = [:]
    private var cachedLinesByDialog: [String: [Line]] = [:]
    private var cachedLocalMessagesByDialog: [String: [LocalMessage]] = [:]
    private var cachedLineDialogOrder: [String] = []
    private var cachedConversationCostByDialog: [String: Int] = [:]
    private var conversationOpenWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
    private var conversationOpenStartedAt: [String: Date] = [:]
    private var loadedLocalMessages: [LocalMessage] = []
    private var timelineTopVisibleMsgId: Int64?
    private var timelineIsAtBottom = true
    private var pendingVisibleReadMessages: [LocalMessage] = []
    private var timelineBeforeCount = 40
    private var timelineAfterCount = 79
    private var dialogSelectionGeneration: UInt64 = 0
    private var timelineLoadGeneration: UInt64 = 0
    private var openingAnchorHydrationGeneration: UInt64 = 0
    private var appliedSyncBatches = 0
    private var lastForegroundSyncFailure: ReplicaSyncState?
    private var timelineForwardCursorByDialog: [String: Int64] = [:]
    private var timelineHasMoreForwardByDialog: [String: Bool] = [:]
    private var readReceiptDrainRequested = false
    #if DEBUG
    private var demoLinesByDialog: [String: [Line]] = [:]
    #endif

    var capabilities: MessagingCapabilities {
        #if DEBUG
        if isDemoMode { return .demo }
        #endif
        return negotiatedCapabilities
    }

    var replicaSyncSnapshot: ReplicaSyncSnapshot {
        ReplicaSyncSnapshot(
            connectivity: replicaConnectivityState,
            updatePhase: replicaUpdatePhase,
            lastSuccessfulServerContact: lastSuccessfulServerContact
        )
    }

    var voiceRecordingLevel: Float { voiceRecorder.level }

    var canRequestCode: Bool {
        let digits = phone.filter(\.isNumber)
        let validLength = phone.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("+992")
            ? digits.count == 12
            : (8...15).contains(digits.count)
        return !authRequestInFlight && resendSeconds == 0 && validLength
    }

    var canVerifyCode: Bool {
        !authVerifyInFlight
            && code.filter(\.isNumber).count == 6
            && !displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        config: CloudConfig = .current,
        tokenStore: TokenStore = TokenStore(),
        pushCenter: PushRegistrationCenter = .shared,
        localStore injectedLocalStore: CloudLocalStore? = nil,
        useDefaultLocalStore: Bool = true,
        capabilityDefaults: UserDefaults = .standard
    ) {
        self.api = CloudAPI(config: config)
        self.tokenStore = tokenStore
        self.pushCenter = pushCenter
        self.mediaEngine = CloudMediaTransferEngine(config: config)
        self.opensDefaultLocalStore = useDefaultLocalStore && injectedLocalStore == nil
        self.capabilityDefaults = capabilityDefaults
        self.capabilityCacheKey = "toj.cloud.capabilities.\(config.baseURL.absoluteString)"
        let cached = capabilityDefaults.object(
            forKey: "toj.cloud.capabilities.\(config.baseURL.absoluteString)"
        ) as? NSNumber
        self.negotiatedCapabilities = cached.map {
            MessagingCapabilities(rawValue: $0.uint16Value)
        } ?? [.replies]
        self.localStore = injectedLocalStore
        voiceRecorder.onUnexpectedStop = { [weak self] in
            guard let self else { return }
            self.recordingTask?.cancel()
            self.recordingTask = nil
            self.composerMode = .text
            self.presentNotice(
                "Recording canceled",
                message: "The microphone or audio route became unavailable. Nothing was sent."
            )
        }
        pushCenter.bind(
            tokenHandler: { [weak self] token, environment in
                await self?.uploadPushToken(token, environment: environment)
            },
            notificationHandler: { [weak self] in
                await self?.syncFromPush() ?? false
            }
        )
    }

    func start() async {
        await prepareForBackgroundRuntime()
        await activateForegroundServices()
    }

    /// Restores the encrypted replica and installs bounded background handlers without starting
    /// sockets, prompting for notifications, or running foreground hydration. UIApplicationDelegate
    /// calls this during a headless BGTask/URLSession launch; the UI calls `start()` on activation.
    func prepareForBackgroundRuntime() async {
        if localRestoreCompleted {
            await finishBackgroundRuntimePreparation()
            return
        }
        if let localRestoreTask {
            await localRestoreTask.value
            await finishBackgroundRuntimePreparation()
            return
        }

        let task = Task { [weak self] in
            guard let self else { return }
            await self.performLocalRestore()
        }
        localRestoreTask = task
        await task.value
        localRestoreTask = nil
        localRestoreCompleted = true
        await finishBackgroundRuntimePreparation()
    }

    private func finishBackgroundRuntimePreparation() async {
        if launchPhase == .localReady, storedSession != nil {
            await prepareBackgroundMediaRuntime()
        } else {
            BackgroundRuntimeCoordinator.shared.completePendingTasksWithNoData()
        }
    }

    private func performLocalRestore() async {
        let launchInterval = LocalFirstMetrics.begin("Local restore")
        defer { LocalFirstMetrics.end("Local restore", launchInterval) }
        launchPhase = .restoringLocal
        do {
            #if DEBUG
            if TelegramFastUITestFixture.enabled {
                try await installTelegramFastUITestFixture()
                return
            }
            #endif
            let pendingRevocation = try await tokenStore.loadPendingRevocationToken()
            let pendingLocalErasure = try await tokenStore.hasPendingLocalErasure()
            let savedSession = try await tokenStore.load()
            if let pendingRevocation {
                Task { [weak self] in await self?.revokeSignedOutToken(pendingRevocation) }
            }
            let revocationMatchesSession = pendingRevocation.map {
                savedSession?.session.token == $0
            } ?? false
            let revocationOutlivedSession = pendingRevocation != nil && savedSession == nil
            if pendingLocalErasure || revocationMatchesSession || revocationOutlivedSession {
                // Sign-out was interrupted. Restore only enough identity to erase its profile,
                // then finish deleting SQLCipher, its key, media, and Keychain session data.
                storedSession = savedSession
                await clearLocalSession(finalStatus: "Signed out")
                return
            }
            if let saved = savedSession {
                storedSession = saved
                phone = saved.phone
                displayName = saved.displayName
                await loadProfileDetails()
                status = "Signed in"
                setReplicaSyncState(.checking)
                await afterSignIn()
            } else {
                status = "Signed out"
                launchPhase = .signedOut
            }
        } catch {
            status = "Session restore failed: \(error.localizedDescription)"
            setReplicaSyncState(.localFailure)
            launchPhase = storedSession == nil ? .signedOut : .recoveringStore
        }
    }

    func retryLocalRecovery() async {
        guard let saved = storedSession else {
            launchPhase = .signedOut
            return
        }
        launchPhase = .restoringLocal
        do {
            // A remote authenticated read is the safety gate: an unreadable replica is preserved
            // until we know its cloud source still exists and this session may rebuild it.
            _ = try await api.getState(token: saved.session.token)
            localStore = try await localStoreBootstrapper.quarantineAndOpenDefaultStore()
            backgroundMediaRuntimePrepared = false
            try await rebuildLocalReplica(token: saved.session.token)
            await afterSignIn()
            await prepareBackgroundMediaRuntime()
            await activateForegroundServices()
        } catch {
            status = "Recovery paused: \(error.localizedDescription)"
            setReplicaSyncState(Self.replicaFailureState(
                for: error,
                network: ReplicaNetworkMonitor.shared.snapshot()
            ))
            launchPhase = .recoveringStore
        }
    }

    func requestCode() async {
        guard canRequestCode else { return }
        let trimmed = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        authRequestInFlight = true
        defer { authRequestInFlight = false }
        do {
            let response = try await api.startAuth(phone: trimmed)
            requestedCode = true
            if let devCode = response.code {
                code = devCode
            }
            startResendCountdown(response.retryAfter ?? 30)
            status = "Code requested"
        } catch {
            if let retryAfter = (error as? CloudAPIError)?.retryAfter {
                startResendCountdown(retryAfter)
            }
            status = "Code request failed: \(error.localizedDescription)"
        }
    }

    func verifyCode() async {
        guard canVerifyCode else { return }
        let trimmedPhone = phone.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedCode = code.filter(\.isNumber)
        let name = displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPhone.isEmpty, !trimmedCode.isEmpty else { return }

        authVerifyInFlight = true
        defer { authVerifyInFlight = false }
        do {
            let session = try await api.checkAuth(
                phone: trimmedPhone,
                code: trimmedCode,
                displayName: name,
                deviceName: UIDevice.current.name
            )
            let stored = StoredCloudSession(session: session, phone: trimmedPhone, displayName: name)
            try await tokenStore.save(stored)
            storedSession = stored
            profileDetails = Self.profileDetails(from: name)
            try? await tokenStore.saveProfile(profileDetails, accountId: session.accountId)
            resendTask?.cancel()
            resendTask = nil
            resendSeconds = 0
            status = "Signed in"
            setReplicaSyncState(.checking)
            await afterSignIn()
            await prepareBackgroundMediaRuntime()
            await activateForegroundServices()
        } catch {
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func dismissOperationNotice() {
        operationNotice = nil
    }

    func resetAuthCode() {
        guard !authRequestInFlight, !authVerifyInFlight else { return }
        requestedCode = false
        code = ""
        status = "Signed out"
    }

    func loadProfileDetails() async {
        guard let saved = storedSession else { return }
        do {
            profileDetails = try await tokenStore.loadProfile(accountId: saved.session.accountId)
                ?? Self.profileDetails(from: saved.displayName)
        } catch {
            profileDetails = Self.profileDetails(from: saved.displayName)
            status = "Could not load profile details"
        }
    }

    @discardableResult
    func saveProfileDetails(_ candidate: StoredProfileDetails) async -> Bool {
        guard let saved = storedSession, !profileSaveInFlight else { return false }
        let cleaned = StoredProfileDetails(
            firstName: Self.cleanedProfileText(candidate.firstName, limit: 48),
            lastName: Self.cleanedProfileText(candidate.lastName, limit: 48),
            bio: Self.cleanedProfileText(candidate.bio, limit: 120, preservesNewlines: true),
            birthday: candidate.birthday,
            colorIndex: max(0, min(candidate.colorIndex, 7)),
            serverUpdatedAt: candidate.serverUpdatedAt,
            pendingSync: true
        )
        guard !cleaned.firstName.isEmpty else {
            status = "First name is required"
            return false
        }

        profileSaveInFlight = true
        defer { profileSaveInFlight = false }
        let updatedSession = StoredCloudSession(
            session: saved.session,
            phone: saved.phone,
            displayName: cleaned.displayName
        )

        do {
            try await tokenStore.saveProfile(cleaned, accountId: saved.session.accountId)
            try await tokenStore.save(updatedSession)
        } catch {
            status = "Could not save profile: \(error.localizedDescription)"
            return false
        }

        profileDetails = cleaned
        storedSession = updatedSession
        displayName = cleaned.displayName
        status = "Profile saved"

        #if DEBUG
        if isDemoMode { return true }
        #endif

        profileSyncTask?.cancel()
        let token = saved.session.token
        profileSyncTask = Task { [weak self] in
            await self?.uploadPendingProfile(cleaned, token: token)
        }
        return true
    }

    private func reconcileProfileWithServer() {
        guard let saved = storedSession else { return }
        #if DEBUG
        if isDemoMode { return }
        #endif
        profileSyncTask?.cancel()
        let local = profileDetails
        profileSyncTask = Task { [weak self] in
            guard let self else { return }
            if local.needsServerSync {
                await self.uploadPendingProfile(local, token: saved.session.token)
                return
            }
            do {
                let profile = try await self.api.getProfile(token: saved.session.token)
                guard !Task.isCancelled else { return }
                await self.acceptCanonicalProfile(profile, token: saved.session.token)
            } catch {
                // Keep the encrypted local snapshot. Reconciliation runs again on the next launch.
            }
        }
    }

    private func uploadPendingProfile(_ local: StoredProfileDetails, token: String) async {
        do {
            let profile = try await api.updateProfile(local, token: token)
            guard !Task.isCancelled else { return }
            await acceptCanonicalProfile(profile, token: token)
            status = "Profile updated everywhere"
        } catch {
            guard !Task.isCancelled else { return }
            status = "Profile saved offline — will sync when reconnected"
        }
    }

    private func acceptCanonicalProfile(_ profile: CloudProfile, token: String) async {
        guard let saved = storedSession, saved.session.token == token else { return }
        let details = Self.profileDetails(from: profile, pendingSync: false)
        let updatedSession = StoredCloudSession(
            session: saved.session,
            phone: saved.phone,
            displayName: details.displayName
        )
        do {
            try await tokenStore.saveProfile(details, accountId: saved.session.accountId)
            try await tokenStore.save(updatedSession)
        } catch {
            status = "Profile updated, but local storage could not be refreshed"
            return
        }
        profileDetails = details
        storedSession = updatedSession
        displayName = details.displayName
    }

    func signOut() async {
        #if DEBUG
        if isDemoMode {
            leaveDemoMode()
            return
        }
        #endif
        let sessionToken = storedSession?.session.token
        if let sessionToken {
            // Save before clearing the active session. If the app is killed or offline, the next
            // launch still has enough information to revoke the server session.
            try? await tokenStore.savePendingRevocationToken(sessionToken)
        }
        await clearLocalSession(finalStatus: "Signed out")
        if let sessionToken {
            Task { [weak self] in await self?.revokeSignedOutToken(sessionToken) }
        }
    }

    func pendingDestructiveLogoutItemCount() async -> Int {
        (try? await localStore?.pendingDestructiveLogoutItemCount()) ?? 0
    }

    private func revokeSignedOutToken(_ token: String) async {
        do {
            _ = try await api.revokeSession(token: token)
            try await tokenStore.clearPendingRevocationToken()
        } catch {
            if revocationIsTerminal(error) {
                try? await tokenStore.clearPendingRevocationToken()
            }
        }
    }

    private func revocationIsTerminal(_ error: Error) -> Bool {
        guard let apiError = error as? CloudAPIError else { return false }
        return apiError.status == 401 || apiError.status == 404
    }

    func loadDevices() async {
        #if DEBUG
        if isDemoMode {
            devices = [
                CloudDevice(
                    id: "demo-device",
                    platform: "ios",
                    deviceName: UIDevice.current.name,
                    createdAt: Self.demoTimestamp(minutesAgo: 1_440),
                    lastSeenAt: Self.demoTimestamp(minutesAgo: 0),
                    current: true
                )
            ]
            return
        }
        #endif
        guard let token = storedSession?.session.token, !loadingDevices else { return }
        loadingDevices = true
        defer { loadingDevices = false }
        do {
            devices = try await api.listDevices(token: token)
            status = "Devices updated"
        } catch {
            status = "Could not load devices: \(error.localizedDescription)"
        }
    }

    func revokeDevice(_ device: CloudDevice) async {
        guard !device.current, let token = storedSession?.session.token else { return }
        do {
            _ = try await api.revokeDevice(id: device.id, token: token)
            devices.removeAll { $0.id == device.id }
            status = "Device signed out"
        } catch {
            status = "Could not revoke device: \(error.localizedDescription)"
        }
    }

    func requestAccountDeletionCode() async -> Bool {
        #if DEBUG
        if isDemoMode {
            accountDeletionRequested = true
            accountDeletionCode = "123456"
            status = "Deletion code requested"
            return true
        }
        #endif
        guard let token = storedSession?.session.token, !accountDeletionInFlight else { return false }
        accountDeletionInFlight = true
        defer { accountDeletionInFlight = false }
        do {
            let response = try await api.startAccountDeletion(token: token)
            accountDeletionRequested = true
            accountDeletionCode = response.code ?? ""
            status = "Deletion code requested"
            return true
        } catch {
            status = "Could not request deletion code: \(error.localizedDescription)"
            return false
        }
    }

    func cancelAccountDeletion() {
        guard !accountDeletionInFlight else { return }
        accountDeletionRequested = false
        accountDeletionCode = ""
    }

    func deleteAccount() async -> Bool {
        #if DEBUG
        if isDemoMode {
            leaveDemoMode()
            return true
        }
        #endif
        guard let saved = storedSession, !accountDeletionInFlight else { return false }
        let digits = accountDeletionCode.filter(\.isNumber)
        guard digits.count == 6 else {
            status = "Enter the 6-digit deletion code"
            return false
        }
        accountDeletionInFlight = true
        defer { accountDeletionInFlight = false }
        // Persist intent before the network call. If the app is killed after the server commits,
        // launch will not restore a now-invalid session or leave the local replica visible.
        try? await tokenStore.savePendingRevocationToken(saved.session.token)
        do {
            _ = try await api.deleteAccount(code: digits, token: saved.session.token)
            await clearLocalSession(finalStatus: "Account deleted")
            try? await tokenStore.clearPendingRevocationToken()
            return true
        } catch {
            if let apiError = error as? CloudAPIError {
                if apiError.status == 401 || apiError.status == 403 {
                    await clearLocalSession(finalStatus: "Session ended")
                    try? await tokenStore.clearPendingRevocationToken()
                    return true
                }
                // The server definitely rejected this request before deletion completed.
                try? await tokenStore.clearPendingRevocationToken()
            }
            status = "Could not confirm account deletion: \(error.localizedDescription)"
            return false
        }
    }

    private func clearLocalSession(finalStatus: String) async {
        let accountId = storedSession?.session.accountId
        var cleanupFailures: [String] = []
        do {
            try await tokenStore.savePendingLocalErasure(accountId: accountId)
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }

        let composerTask = composerMediaTask
        let transferTasks = Array(mediaTransferTasks.values)
        let pendingRetryTask = retryTask
        let backgroundTasks: [Task<Void, Never>] = [
            hintTask, networkObservationTask, memoryPressureTask,
            pendingRetryTask, resendTask, recordingTask,
            composerTask, profileSyncTask,
            profilePhotoMigrationTask,
            postSignInTask, postSyncWorkTask, historyHydrationTask, dialogObservationTask,
            openingAnchorHydrationTask,
            timelineObservationTask, viewportPersistenceTask, mediaDownloadTask,
            readReceiptRetryTask, replicaIntegrityTask,
        ].compactMap { $0 }
        backgroundTasks.forEach { $0.cancel() }
        transferTasks.forEach { $0.cancel() }
        voiceRecorder.cancel()
        await hintSocket?.stop()
        hintSocket = nil
        await replicaSyncCoordinator.stop()
        await mediaPrefetchScheduler.stop()
        mediaSchedulerForegrounded = false
        await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
        for task in backgroundTasks { await task.value }
        for task in transferTasks { await task.value }
        hintTask = nil
        networkObservationTask = nil
        memoryPressureTask = nil
        retryTask = nil
        resendTask = nil
        recordingTask = nil
        composerMediaTask = nil
        profileSyncTask = nil
        profilePhotoMigrationTask = nil
        postSignInTask = nil
        postSyncWorkTask = nil
        historyHydrationTask = nil
        openingAnchorHydrationTask = nil
        dialogObservationTask = nil
        timelineObservationTask = nil
        viewportPersistenceTask = nil
        mediaDownloadTask = nil
        readReceiptRetryTask = nil
        replicaIntegrityTask = nil
        composerMediaOperationId = nil
        activeComposerTransferId = nil
        mediaTransferTasks.removeAll()
        mediaTransfersInFlight.removeAll()
        messageMutationsInFlight.removeAll()
        mutationTargetsBeingQueued.removeAll()
        syncInFlight = false
        syncAgain = false
        appliedSyncBatches = 0
        lastForegroundSyncFailure = nil
        lastSuccessfulServerContact = nil
        retryInFlight = false

        await mediaEngine.destroyLocalStateForLogout()
        MediaPresentationCache.shared.removeAll()
        backgroundMediaRuntimePrepared = false
        mediaCacheBytes = 0

        do {
            try await tokenStore.clearAllProfiles()
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }

        if opensDefaultLocalStore {
            // Both references must be released before removing WAL/SHM and the SQLCipher key.
            localStore = nil
            do {
                try await localStoreBootstrapper.destroyDefaultMediaState()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
            do {
                try await localStoreBootstrapper.destroyDefaultStore()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        } else if let accountId {
            do {
                try await localStore?.clearAccount(accountId: accountId)
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }

        do {
            try await tokenStore.clear()
        } catch {
            cleanupFailures.append(error.localizedDescription)
        }
        if cleanupFailures.isEmpty {
            do {
                try await tokenStore.clearPendingLocalErasure()
            } catch {
                cleanupFailures.append(error.localizedDescription)
            }
        }
        storedSession = nil
        activeDialogId = nil
        dialogs = []
        lines = []
        loadedLocalMessages = []
        pendingVisibleReadMessages = []
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        timelineBeforeCount = 40
        timelineAfterCount = 79
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false
        historyHasMoreByDialog = [:]
        timelineForwardCursorByDialog = [:]
        timelineHasMoreForwardByDialog = [:]
        draftsByDialog = [:]
        cachedLinesByDialog = [:]
        cachedLocalMessagesByDialog = [:]
        cachedLineDialogOrder = []
        cachedConversationCostByDialog = [:]
        devices = []
        loadingDevices = false
        uploadedPushRegistration = nil
        pts = 0
        phone = "+992 "
        displayName = ""
        peerPhone = ""
        draft = ""
        requestedCode = false
        authRequestInFlight = false
        authVerifyInFlight = false
        resendSeconds = 0
        code = ""
        accountDeletionRequested = false
        accountDeletionInFlight = false
        accountDeletionCode = ""
        profileDetails = .empty
        profileSaveInFlight = false
        composerMode = .text
        operationNotice = nil
        #if DEBUG
        demoLinesByDialog = [:]
        #endif
        launchPhase = .signedOut
        conversationOpenState = .loadingLocal
        setReplicaSyncState(.offline)
        status = cleanupFailures.isEmpty
            ? finalStatus
            : "Signed out; local cleanup needs another attempt"
    }

    func refreshMediaCacheUsage() async {
        if let localStore {
            mediaCacheBytes = await mediaEngine.cacheUsageBytes(localStore: localStore)
        } else {
            mediaCacheBytes = await mediaEngine.cacheUsageBytes()
        }
    }

    func loadMediaPolicies() async {
        mediaAutoDownloadPolicy = await mediaEngine.currentAutoDownloadPolicy()
        mediaCachePolicy = await mediaEngine.currentCachePolicy()
    }

    func updateMediaAutoDownloadPolicy(_ policy: MediaAutoDownloadPolicy) async {
        do {
            try await mediaEngine.updateAutoDownloadPolicy(policy)
            mediaAutoDownloadPolicy = policy
        } catch {
            status = "Could not save automatic download settings"
        }
    }

    func updateMediaCachePolicy(_ policy: MediaCachePolicy) async {
        do {
            try await mediaEngine.updateCachePolicy(policy)
            mediaCachePolicy = policy
            await refreshMediaCacheUsage()
        } catch {
            status = "Could not save media cache settings"
        }
    }

    func clearMediaCache() async {
        guard !clearingMediaCache else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        MediaPresentationCache.shared.removeAll()
        if let localStore {
            await mediaEngine.clearDownloadedCache(localStore: localStore)
        } else {
            await mediaEngine.clearDownloadedCache()
        }
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func clearMediaCache(kind: String) async {
        guard !clearingMediaCache, let localStore else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        let mediaIds = (try? await localStore.mediaIds(kind: kind)) ?? []
        MediaPresentationCache.shared.invalidate(mediaIds: mediaIds)
        await mediaEngine.clearMediaCache(mediaIds: mediaIds, localStore: localStore)
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    func clearMediaCache(dialogId: String) async {
        guard !clearingMediaCache, let localStore else { return }
        clearingMediaCache = true
        defer { clearingMediaCache = false }
        let mediaIds = (try? await localStore.mediaIds(dialogId: dialogId)) ?? []
        MediaPresentationCache.shared.invalidate(mediaIds: mediaIds)
        await mediaEngine.clearMediaCache(mediaIds: mediaIds, localStore: localStore)
        await refreshMediaCacheUsage()
        status = "Downloaded media cleared"
    }

    private func queueMediaDownloads(
        _ mediaItems: [CloudMedia],
        dialogId: String?,
        visible: Bool
    ) async {
        guard visible, !mediaItems.isEmpty, let localStore else { return }
        let snapshot = ReplicaNetworkMonitor.shared.snapshot()
        let network = snapshot.mediaNetworkClass
        let chat = if let dialogId {
            (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
        } else {
            MediaChatClass.privateChat
        }

        for media in mediaItems {
            _ = await mediaEngine.enqueueAutoDownload(
                media: media,
                chat: chat,
                network: network,
                dialogId: dialogId,
                localStore: localStore,
                visible: visible
            )
        }
        scheduleMediaDownloadProcessing()
    }

    private func scheduleMediaDownloadProcessing() {
        guard mediaDownloadTask == nil else { return }
        mediaDownloadTask = Task { [weak self] in
            guard let self else { return }
            let networkClass = ReplicaNetworkMonitor.shared.snapshot().networkClass
            await self.mediaPrefetchScheduler.wake(networkClass: networkClass)
            self.mediaDownloadTask = nil
        }
    }

    private func processMediaDownloadJobs(maximumJobs: Int) async {
        for _ in 0..<maximumJobs {
            guard await processOneMediaDownload(component: nil) else { break }
        }
        await refreshMediaCacheUsage()
        guard let localStore else { return }
        let remainingJobs = try? await localStore.mediaDownloadJobsReady(limit: 1)
        if remainingJobs?.isEmpty == false {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing(
                earliestBeginDate: Date(timeIntervalSinceNow: 60)
            )
        } else if let nextRetry = try? await localStore.nextMediaDownloadRetryDate() {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing(earliestBeginDate: nextRetry)
        }
    }

    private func processOneMediaDownload(component: MediaDownloadComponent?) async -> Bool {
        let networkSnapshot = ReplicaNetworkMonitor.shared.snapshot()
        guard networkSnapshot.allowsEssentialSync,
              let token = storedSession?.session.token,
              let localStore,
              !Task.isCancelled else { return false }
        guard let item = await mediaEngine.dequeueAutoDownload(
            localStore: localStore,
            component: component
        ) else { return false }
        let readyCount = (try? await localStore.mediaDownloadJobsReady(limit: 200).count) ?? 0
        LocalFirstMetrics.queueDepth(readyCount)
        let chat = if let dialogId = item.dialogId {
            (try? await localStore.mediaChatClass(dialogId: dialogId)) ?? .privateChat
        } else {
            MediaChatClass.privateChat
        }
        do {
            // Revalidate the live policy and path after the durable claim; scrolling, roaming, and
            // Low Data Mode can all change while a job waits in SQLCipher.
            let currentNetwork = ReplicaNetworkMonitor.shared.snapshot()
            try await mediaEngine.performAutoDownload(
                item,
                token: token,
                localStore: localStore,
                chat: chat,
                network: currentNetwork.mediaNetworkClass
            )
            if item.component == .thumbnail,
               item.media.kind == "photo" || item.media.kind == "video" {
                _ = await presentationImage(for: item.media, variant: .bubble720)
            } else if item.component == .fullMedia, item.media.kind == "photo" {
                _ = await presentationImage(for: item.media, variant: .screen2048)
            } else if item.component == .fullMedia, item.media.kind == "video" {
                _ = await presentationImage(for: item.media, variant: .videoPoster)
                await prewarmStreamingVideoAssetIfLocal(for: item.media)
            }
            return true
        } catch is CancellationError {
            return false
        } catch {
            if await mediaEngine.areAutomaticDownloadsSuspendedForLowDisk(),
               operationNotice?.title != "Storage needed for media" {
                presentNotice(
                    "Storage needed for media",
                    message: "Toj kept your saved chats, but paused new automatic media downloads to preserve free space."
                )
            }
            if let nextRetry = try? await localStore.nextMediaDownloadRetryDate() {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing(earliestBeginDate: nextRetry)
            }
            if case .authenticationRequired = cloudFailureDisposition(error) { return false }
            return true
        }
    }

    private func startResendCountdown(_ seconds: Int) {
        resendTask?.cancel()
        resendSeconds = max(0, seconds)
        guard resendSeconds > 0 else {
            resendTask = nil
            return
        }
        resendTask = Task { [weak self] in
            while let self, self.resendSeconds > 0, !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard !Task.isCancelled else { return }
                self.resendSeconds -= 1
            }
            self?.resendTask = nil
        }
    }

    func openPeer() async -> String? {
        #if DEBUG
        if isDemoMode {
            let trimmed = peerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return nil }
            let dialogId = "demo-\(trimmed.filter(\.isNumber))"
            if !dialogs.contains(where: { $0.id == dialogId }) {
                dialogs.insert(Dialog(
                    id: dialogId,
                    title: trimmed,
                    subtitle: String(localized: "Demo conversation"),
                    updatedAt: Self.demoTimestamp(minutesAgo: 0),
                    isPending: false,
                    unreadCount: 0
                ), at: 0)
                demoLinesByDialog[dialogId] = [Line(
                    id: UUID().uuidString,
                    dialogId: dialogId,
                    msgId: 1,
                    clientMsgId: UUID().uuidString,
                    text: String(localized: "This chat is local to demo mode."),
                    mine: false,
                    delivery: .sent,
                    timestamp: Self.demoTimestamp(minutesAgo: 0)
                )]
            }
            peerPhone = ""
            await selectDialog(dialogId)
            status = "Chat ready"
            return dialogId
        }
        #endif
        guard let token = storedSession?.session.token else { return nil }
        let trimmed = peerPhone.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        do {
            status = "Looking up contact"
            let found = try await api.lookupContact(phone: trimmed, token: token)
            guard let peerAccountId = found.accountId else {
                status = "No account found"
                return nil
            }
            let dialog = try await api.createDirectDialog(peerAccountId: peerAccountId, token: token)
            let title = displayTitle(found.displayName, fallback: trimmed)
            try await localStore?.upsertDialog(dialogId: dialog.dialogId, title: title)
            if let accountId = storedSession?.session.accountId {
                try await localStore?.saveMembers(dialogId: dialog.dialogId, members: [
                    BootstrapDialogMember(accountId: accountId, role: "member", lastReadMsgId: 0),
                    BootstrapDialogMember(accountId: peerAccountId, role: "member", lastReadMsgId: 0)
                ])
            }
            if let profile = Self.cloudProfile(from: found) {
                try await localStore?.saveProfile(profile)
            }
            await refreshDialogs()
            await selectDialog(dialog.dialogId)
            status = "Chat ready"
            scheduleSync()
            return dialog.dialogId
        } catch {
            status = "Open chat failed: \(error.localizedDescription)"
            return nil
        }
    }

    func contactIdentity(phone: String) async throws -> ContactIdentity? {
        #if DEBUG
        if isDemoMode {
            let digits = phone.filter(\.isNumber)
            guard let last = digits.last?.wholeNumberValue, last.isMultiple(of: 2) else { return nil }
            return ContactIdentity(accountId: "demo-contact-\(digits)", displayName: phone)
        }
        #endif
        guard let token = storedSession?.session.token else { return nil }
        let found = try await api.lookupContact(phone: phone, token: token)
        guard let accountId = found.accountId else { return nil }
        return ContactIdentity(
            accountId: accountId,
            displayName: displayTitle(found.displayName, fallback: phone),
            bio: found.bio,
            birthday: found.birthday,
            colorIndex: found.colorIndex
        )
    }

    func openPeer(phone: String) async -> String? {
        peerPhone = phone
        return await openPeer()
    }

    func selectDialog(_ dialogId: String) async {
        if activeDialogId != dialogId || timelineObservationTask == nil {
            beginConversationSelection(dialogId)
        }
        guard activeDialogId == dialogId, conversationOpenState == .loadingLocal else { return }
        await withCheckedContinuation { continuation in
            guard activeDialogId == dialogId, conversationOpenState == .loadingLocal else {
                continuation.resume()
                return
            }
            conversationOpenWaiters[dialogId, default: []].append(continuation)
        }
    }

    /// Starts the encrypted local observation before the navigation animation begins. This method
    /// performs no network work and publishes an LRU hit in the same main-actor turn as the tap.
    func prepareConversationOpen(dialogId: String) {
        guard activeDialogId != dialogId || timelineObservationTask == nil else { return }
        beginConversationSelection(dialogId)
    }

    private func beginConversationSelection(_ dialogId: String) {
        if let previousDialogId = activeDialogId, previousDialogId != dialogId {
            conversationOpenStartedAt.removeValue(forKey: previousDialogId)
            finishConversationOpenWaiters(dialogId: previousDialogId)
        }
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        if let activeDialogId {
            draftsByDialog[activeDialogId] = draft
        }
        activeDialogId = dialogId
        conversationOpenStartedAt[dialogId] = Date()
        dialogSelectionGeneration &+= 1
        draft = draftsByDialog[dialogId] ?? ""
        composerMode = .text
        timelineBeforeCount = 40
        timelineAfterCount = 79
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        pendingVisibleReadMessages = []
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false

        // Publish the in-memory LRU synchronously. Returning chats never wait for Keychain,
        // SQLCipher, anchor resolution, or any network operation before cached bubbles appear.
        let hasPreparedSnapshot = cachedLinesByDialog[dialogId] != nil
        lines = cachedLinesByDialog[dialogId] ?? []
        loadedLocalMessages = cachedLocalMessagesByDialog[dialogId] ?? []
        conversationOpenState = hasPreparedSnapshot ? .cached : .loadingLocal
        #if DEBUG
        if isDemoMode {
            openingTimelineAnchor = .bottom
            timelineIsAtBottom = true
            timelineTopVisibleMsgId = nil
            lines = demoLinesByDialog[dialogId] ?? []
            canLoadEarlier = false
            dialogs = dialogs.map { dialog in
                guard dialog.id == dialogId, dialog.unreadCount > 0 else { return dialog }
                var updated = dialog
                updated.unreadCount = 0
                updated.mentionCount = 0
                return updated
            }
            conversationOpenState = lines.isEmpty ? .empty : .ready
            recordConversationLocalReady(dialogId: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            return
        }
        #endif
        startTimelineObservation(dialogId: dialogId)
    }

    func retryConversationLocalLoad() {
        guard let activeDialogId else { return }
        conversationOpenState = cachedLinesByDialog[activeDialogId] == nil ? .loadingLocal : .cached
        startTimelineObservation(dialogId: activeDialogId)
    }

    func deselectDialog(_ dialogId: String) {
        guard activeDialogId == dialogId else { return }
        conversationOpenStartedAt.removeValue(forKey: dialogId)
        finishConversationOpenWaiters(dialogId: dialogId)
        draftsByDialog[dialogId] = draft
        cacheCurrentLines(for: dialogId)
        timelineObservationTask?.cancel()
        timelineObservationTask = nil
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = nil
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        activeDialogId = nil
        conversationOpenState = .loadingLocal
        draft = ""
        composerMode = .text
        canLoadEarlier = false
        loadingEarlier = false
        canLoadLater = false
        loadingLater = false
        dialogSelectionGeneration &+= 1
        timelineLoadGeneration &+= 1
        pendingVisibleReadMessages = []
    }

    /// Captures the semantic anchor and visible-read watermark before navigation tears down the
    /// conversation. Unlike the regular viewport updates, this final write is not debounced.
    func flushAndDeselectDialog(_ dialogId: String) async {
        guard activeDialogId == dialogId else { return }
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = nil
        let accountId = storedSession?.session.accountId
        let store = localStore
        let state = accountId.map {
            ChatViewportState(
                dialogId: dialogId,
                accountId: $0,
                topVisibleMsgId: timelineIsAtBottom ? nil : timelineTopVisibleMsgId,
                wasAtBottom: timelineIsAtBottom
            )
        }
        let visibleMessages = pendingVisibleReadMessages

        // Clear presentation state synchronously, before the first suspension point, so a quick
        // navigation into another conversation cannot be undone by this closing task.
        deselectDialog(dialogId)
        if let state, let store {
            try? await store.saveViewportState(state)
            await markReadIfNeeded(dialogId: dialogId, messages: visibleMessages)
        }
    }

    func jumpToLatest(_ dialogId: String) async {
        guard activeDialogId == dialogId else { return }
        openingAnchorHydrationGeneration &+= 1
        openingAnchorHydrationTask?.cancel()
        openingAnchorHydrationTask = nil
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        timelineBeforeCount = 40
        timelineAfterCount = 79
        await loadLocalLines(dialogId: dialogId)
    }

    private func startOpeningAnchorHydration(dialogId: String, candidateMsgId: Int64) {
        guard openingAnchorHydrationTask == nil else { return }
        openingAnchorHydrationGeneration &+= 1
        let generation = openingAnchorHydrationGeneration
        openingAnchorHydrationTask = Task { [weak self] in
            guard let self else { return }
            await self.hydrateOpeningAnchor(dialogId: dialogId, candidateMsgId: candidateMsgId)
            if self.openingAnchorHydrationGeneration == generation {
                self.openingAnchorHydrationTask = nil
            }
        }
    }

    /// A bootstrap intentionally carries only five recent messages. Fetch forward from the
    /// persisted read watermark so a large unread gap resolves to the real first unread without
    /// making the initial cached render wait for the network.
    private func hydrateOpeningAnchor(dialogId: String, candidateMsgId: Int64) async {
        guard let token = storedSession?.session.token,
              let accountId = storedSession?.session.accountId,
              let localStore else { return }
        var afterMsgId = max(0, candidateMsgId - 1)
        if timelineHasMoreForwardByDialog[dialogId] == true,
           let savedCursor = timelineForwardCursorByDialog[dialogId] {
            afterMsgId = max(afterMsgId, savedCursor)
        }
        var resolvedUnreadMsgId: Int64?
        var reachedEnd = false
        var pagesFetched = 0

        while true {
            if Task.isCancelled || activeDialogId != dialogId || storedSession?.session.token != token {
                return
            }
            do {
                let page = try await api.getHistory(
                    dialogId: dialogId,
                    beforeMsgId: nil,
                    afterMsgId: afterMsgId,
                    limit: TimelineWindow.initialLimit,
                    token: token
                )
                try await localStore.applyTargetedHistoryPage(page)
                timelineHasMoreForwardByDialog[dialogId] = page.hasMore
                if let next = page.nextAfterMsgId {
                    timelineForwardCursorByDialog[dialogId] = next
                }
                if case let .firstUnread(msgId) = try await localStore.resolveOpeningAnchor(
                    dialogId: dialogId,
                    accountId: accountId
                ) {
                    resolvedUnreadMsgId = msgId
                    break
                }
                guard page.hasMore,
                      let next = page.nextAfterMsgId,
                      next > afterMsgId else {
                    reachedEnd = true
                    break
                }
                afterMsgId = next
                pagesFetched += 1
                if pagesFetched.isMultiple(of: 24) {
                    // A very large unread gap must stay correct without monopolizing the executor.
                    await Task.yield()
                }
            } catch is CancellationError {
                return
            } catch {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                return
            }
        }

        guard activeDialogId == dialogId else { return }
        if let resolvedUnreadMsgId {
            openingTimelineAnchor = .firstUnread(msgId: resolvedUnreadMsgId)
            timelineTopVisibleMsgId = resolvedUnreadMsgId
            timelineIsAtBottom = false
        } else if reachedEnd {
            timelineHasMoreForwardByDialog[dialogId] = false
            openingTimelineAnchor = .bottom
            timelineTopVisibleMsgId = nil
            timelineIsAtBottom = true
        }
        await loadLocalLines(dialogId: dialogId)
    }

    func dialogs(matching query: String) -> [Dialog] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dialogs }
        return dialogs.filter {
            $0.title.localizedStandardContains(trimmed)
                || $0.subtitle.localizedStandardContains(trimmed)
        }
    }

    func dialogs(matching query: String, scope: SearchScope) -> [Dialog] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return dialogs.filter { !$0.isArchived } }

        switch scope {
        case .chats:
            return dialogs.filter {
                !$0.isArchived && ($0.title.localizedStandardContains(trimmed) || $0.subtitle.localizedStandardContains(trimmed))
            }
        case .people:
            return dialogs.filter { !$0.isArchived && $0.title.localizedStandardContains(trimmed) }
        case .messages:
            #if DEBUG
            if isDemoMode {
                let matchingIds = Set(demoLinesByDialog.compactMap { dialogId, lines in
                    lines.contains(where: { $0.text.localizedStandardContains(trimmed) }) ? dialogId : nil
                })
                return dialogs.filter { matchingIds.contains($0.id) }
            }
            #endif
            return dialogs(matching: trimmed)
        case .media, .links, .files:
            #if DEBUG
            if isDemoMode {
                let matchingIds = Set(demoLinesByDialog.compactMap { dialogId, lines in
                    let matches = lines.contains { line in
                        guard let attachment = line.attachment else { return false }
                        let typeMatches: Bool
                        switch (scope, attachment) {
                        case (.media, .photo), (.media, .video), (.links, .link), (.files, .file): typeMatches = true
                        default: typeMatches = false
                        }
                        return typeMatches && (
                            attachment.title.localizedStandardContains(trimmed)
                                || line.text.localizedStandardContains(trimmed)
                        )
                    }
                    return matches ? dialogId : nil
                })
                return dialogs.filter { matchingIds.contains($0.id) }
            }
            #endif
            return []
        }
    }

    func loadEarlier() async {
        guard !loadingEarlier else { return }
        guard let dialogId = activeDialogId, let localStore else { return }
        let selectionGeneration = dialogSelectionGeneration
        let preservedAnchor = timelineTopVisibleMsgId
            ?? loadedLocalMessages.compactMap(\.msgId).min()

        loadingEarlier = true
        defer {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                loadingEarlier = false
            }
        }

        do {
            let loadedOldest = loadedLocalMessages.compactMap(\.msgId).min()
            let storedOldest = try await localStore.oldestServerMsgId(dialogId: dialogId)
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            guard let beforeMsgId = loadedOldest ?? storedOldest else {
                canLoadEarlier = false
                historyHasMoreByDialog[dialogId] = false
                return
            }

            let earlierLocal = try await localStore.messages(
                dialogId: dialogId,
                limit: TimelineWindow.pageLimit,
                beforeMsgId: beforeMsgId
            )
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            if !earlierLocal.isEmpty {
                // Grow the window around the semantic viewport row; never replace it with the
                // page cursor. SwiftUI restores the same visible target after the prepend.
                timelineTopVisibleMsgId = preservedAnchor
                timelineIsAtBottom = false
                timelineBeforeCount = min(
                    TimelineWindow.maximumRetainedMessages - 1,
                    timelineBeforeCount + TimelineWindow.pageLimit
                )
                timelineAfterCount = min(
                    timelineAfterCount,
                    TimelineWindow.maximumRetainedMessages - timelineBeforeCount - 1
                )
                await loadLocalLines(dialogId: dialogId)
                status = "Earlier messages loaded"
                return
            }

            if let historyState = try await localStore.loadHistoryState(dialogId: dialogId),
               historyState.historyComplete {
                canLoadEarlier = false
                return
            }

            guard let token = storedSession?.session.token else {
                status = "Offline — cached history shown"
                return
            }

            let page = try await api.getHistory(
                dialogId: dialogId,
                beforeMsgId: beforeMsgId,
                limit: TimelineWindow.pageLimit,
                token: token
            )
            try await localStore.applyHistoryPage(page)
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            historyHasMoreByDialog[dialogId] = page.hasMore
            let currentState = try await localStore.loadHistoryState(dialogId: dialogId)
            try await localStore.saveHistoryState(
                DialogHistoryState(
                    dialogId: dialogId,
                    ceilingMsgId: currentState?.ceilingMsgId
                        ?? loadedLocalMessages.compactMap(\.msgId).max()
                        ?? 0,
                    nextBeforeMsgId: page.nextBeforeMsgId,
                    historyComplete: !page.hasMore
                )
            )
            guard activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration else {
                return
            }
            timelineTopVisibleMsgId = preservedAnchor
            timelineIsAtBottom = false
            timelineBeforeCount = min(
                TimelineWindow.maximumRetainedMessages - 1,
                timelineBeforeCount + TimelineWindow.pageLimit
            )
            timelineAfterCount = min(
                timelineAfterCount,
                TimelineWindow.maximumRetainedMessages - timelineBeforeCount - 1
            )
            await loadLocalLines(dialogId: dialogId)
            status = page.messages.isEmpty ? "No earlier messages" : "History loaded"
        } catch {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                status = "History failed: \(error.localizedDescription)"
            }
        }
    }

    /// Extends a centered unread/saved window toward newer rows. Local pages are exposed first;
    /// when a targeted forward fetch reported another page, its keyset cursor resumes that fetch.
    func loadLater() async {
        guard !loadingLater, canLoadLater else { return }
        guard let dialogId = activeDialogId, let localStore else { return }
        let selectionGeneration = dialogSelectionGeneration
        loadingLater = true
        defer {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                loadingLater = false
            }
        }

        do {
            let loadedNewest = loadedLocalMessages.compactMap(\.msgId).max()
            var forwardFetchAfterMsgId: Int64?
            if let loadedNewest {
                let newerLocal = try await localStore.messages(
                    dialogId: dialogId,
                    limit: 1,
                    afterMsgId: loadedNewest
                )
                guard activeDialogId == dialogId,
                      dialogSelectionGeneration == selectionGeneration else { return }
                if newerLocal.first?.msgId == loadedNewest + 1 {
                    timelineAfterCount = min(
                        TimelineWindow.maximumRetainedMessages - 1,
                        timelineAfterCount + TimelineWindow.pageLimit
                    )
                    timelineBeforeCount = min(
                        timelineBeforeCount,
                        TimelineWindow.maximumRetainedMessages - timelineAfterCount - 1
                    )
                    await loadLocalLines(dialogId: dialogId)
                    return
                }
                if newerLocal.first?.msgId != nil
                    || timelineHasMoreForwardByDialog[dialogId] == true {
                    // A non-contiguous newer local row is usually the five-message bootstrap
                    // preview. Fill the missing server range before it is allowed on screen.
                    forwardFetchAfterMsgId = loadedNewest
                }
            } else if timelineHasMoreForwardByDialog[dialogId] == true {
                forwardFetchAfterMsgId = timelineForwardCursorByDialog[dialogId]
            }

            guard let afterMsgId = forwardFetchAfterMsgId else {
                canLoadLater = false
                return
            }
            guard let token = storedSession?.session.token else { return }
            let page = try await api.getHistory(
                dialogId: dialogId,
                beforeMsgId: nil,
                afterMsgId: afterMsgId,
                limit: TimelineWindow.pageLimit,
                token: token
            )
            try await localStore.applyTargetedHistoryPage(page)
            guard activeDialogId == dialogId,
                  dialogSelectionGeneration == selectionGeneration else { return }
            timelineHasMoreForwardByDialog[dialogId] = page.hasMore
            if let next = page.nextAfterMsgId {
                timelineForwardCursorByDialog[dialogId] = next
            }
            timelineAfterCount = min(
                TimelineWindow.maximumRetainedMessages - 1,
                timelineAfterCount + TimelineWindow.pageLimit
            )
            timelineBeforeCount = min(
                timelineBeforeCount,
                TimelineWindow.maximumRetainedMessages - timelineAfterCount - 1
            )
            await loadLocalLines(dialogId: dialogId)
        } catch is CancellationError {
            return
        } catch {
            if activeDialogId == dialogId, dialogSelectionGeneration == selectionGeneration {
                status = "Newer history failed: \(error.localizedDescription)"
            }
        }
    }

    func dialogTitle(_ dialogId: String) -> String {
        dialogs.first(where: { $0.id == dialogId })?.title ?? shortDialogId(dialogId)
    }

    func sendDraft() async {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        if case let .editing(messageId, _) = composerMode {
            #if DEBUG
            if isDemoMode {
                updateDemoMessage(messageId: messageId, text: text)
                draft = ""
                composerMode = .text
                return
            }
            #endif
            guard let line = lines.first(where: { $0.id == messageId }) else {
                status = "Message is no longer available"
                return
            }
            await edit(line, text: text)
            return
        }
        let replyPreview: String?
        let replyToMsgId: Int64?
        if case let .replying(messageId, preview) = composerMode {
            replyPreview = preview
            replyToMsgId = lines.first(where: { $0.id == messageId })?.msgId
            guard replyToMsgId != nil else {
                status = "Reply target is not available yet"
                return
            }
        } else {
            replyPreview = nil
            replyToMsgId = nil
        }
        draft = ""
        composerMode = .text
        #if DEBUG
        if isDemoMode {
            sendDemo(text, replyPreview: replyPreview)
            return
        }
        #endif
        await send(text, replyToMsgId: replyToMsgId)
    }

    func beginReply(to line: Line) {
        guard capabilities.contains(.replies), !line.isDeleted, line.msgId != nil else { return }
        composerMode = .replying(messageId: line.id, preview: line.text)
    }

    func beginEditing(_ line: Line) {
        guard line.mine, !line.isDeleted, line.msgId != nil, capabilities.contains(.editing) else { return }
        composerMode = .editing(messageId: line.id, original: line.text)
        draft = line.text
    }

    func cancelComposerMode() {
        if case .recording = composerMode {
            cancelVoiceRecording()
            return
        }
        if case .uploading = composerMode {
            if let transferId = activeComposerTransferId {
                mediaTransferTasks[transferId]?.cancel()
            }
            composerMediaTask?.cancel()
            composerMode = .text
            return
        }
        if case let .editing(_, original) = composerMode, draft == original {
            draft = ""
        }
        composerMode = .text
    }

    func actions(for line: Line) -> [MessageAction] {
        if line.isDeleted { return [.inspect] }
        if line.pendingMutation != nil { return [.inspect] }
        var actions: [MessageAction] = line.text.isEmpty ? [] : [.copy]
        if capabilities.contains(.replies) { actions.insert(.reply, at: 0) }
        if line.msgId != nil, capabilities.contains(.reactions) { actions.insert(.react, at: min(1, actions.count)) }
        if line.mine, line.media == nil, capabilities.contains(.editing) { actions.append(.edit) }
        if line.msgId != nil, capabilities.contains(.forwarding) { actions.append(.forward) }
        if line.mine, capabilities.contains(.deletion) { actions.append(.delete) }
        if case .failed = line.delivery { actions.append(.retry) }
        actions.append(.inspect)
        return actions
    }

    func retryFailedMessage(_ line: Line) {
        guard case .failed = line.delivery else { return }
        Task { [weak self] in
            guard let self else { return }
            if let localStore = self.localStore {
                try? await localStore.markRetrying(clientMsgId: line.clientMsgId)
                try? await localStore.markMediaRetrying(clientMsgId: line.clientMsgId)
                if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                    await self.loadLocalLines(dialogId: dialogId)
                }
            }
            self.scheduleOutboxRetry()
        }
    }

    func removeFailedMedia(_ line: Line) {
        guard line.media != nil else { return }
        Task { [weak self] in
            guard let self, let localStore,
                  let transfer = try? await localStore.mediaTransfer(clientMsgId: line.clientMsgId)
            else { return }
            if let activeTask = mediaTransferTasks[transfer.transferId] {
                activeTask.cancel()
                await activeTask.value
                return
            }
            if let token = storedSession?.session.token {
                await cancelMediaTransfer(transfer, token: token)
            } else {
                try? await localStore.cancelMediaTransfer(
                    transferId: transfer.transferId, clientMsgId: transfer.clientMsgId
                )
                await mediaEngine.discardTransfer(transfer)
                if activeDialogId == transfer.dialogId { await loadLocalLines(dialogId: transfer.dialogId) }
            }
        }
    }

    func togglePinned(_ dialogId: String) {
        guard capabilities.contains(.chatOrganization) else { return }
        updateDialog(dialogId) { $0.isPinned.toggle() }
        sortDialogsForPresentation()
    }

    func toggleMuted(_ dialogId: String) {
        guard capabilities.contains(.chatOrganization) else { return }
        updateDialog(dialogId) { $0.isMuted.toggle() }
    }

    func archive(_ dialogId: String) {
        guard capabilities.contains(.chatOrganization) else { return }
        updateDialog(dialogId) { $0.isArchived = true }
    }

    private func updateDialog(_ dialogId: String, mutation: (inout Dialog) -> Void) {
        guard let index = dialogs.firstIndex(where: { $0.id == dialogId }) else { return }
        mutation(&dialogs[index])
    }

    private func sortDialogsForPresentation() {
        dialogs.sort {
            if $0.isPinned != $1.isPinned { return $0.isPinned }
            return $0.updatedAt > $1.updatedAt
        }
    }

    private func send(_ text: String, replyToMsgId: Int64? = nil) async {
        guard let token = storedSession?.session.token, let dialogId = activeDialogId else { return }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        let clientMsgId = UUID().uuidString.lowercased()
        do {
            if let localStore, let accountId = storedSession?.session.accountId {
                _ = try await localStore.insertSending(
                    dialogId: dialogId,
                    clientMsgId: clientMsgId,
                    text: text,
                    senderAccountId: accountId,
                    replyToMsgId: replyToMsgId
                )
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
            } else {
                lines.append(Line(
                    id: clientMsgId,
                    dialogId: dialogId,
                    msgId: nil,
                    clientMsgId: clientMsgId,
                    text: text,
                    mine: true,
                    delivery: .sending,
                    timestamp: nil,
                    replyToMsgId: replyToMsgId
                ))
            }
        } catch {
            status = "Local send failed: \(error.localizedDescription)"
            return
        }

        do {
            try await sendOutboxItem(
                PendingOutboxItem(
                    clientMsgId: clientMsgId,
                    dialogId: dialogId,
                    body: text,
                    replyToMsgId: replyToMsgId,
                    forwardedFromDialogId: nil,
                    forwardedFromMsgId: nil,
                    retryCount: 0,
                    nextRetryAt: nil
                ),
                token: token
            )
        } catch {
            if let localStore {
                let disposition = cloudOperationFailureDisposition(
                    error, serverAdvertisesFeature: capabilities.contains(.replies)
                )
                if case let .transient(retryAfter) = disposition {
                    let delay = retryAfter ?? retryDelay(forRetryCount: 1)
                    try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: delay)
                    scheduleOutboxRetry(after: delay)
                    publishTransportFailure(error)
                } else {
                    try? await localStore.markFailed(clientMsgId: clientMsgId, terminal: true)
                    presentNotice("Message was not sent", message: error.localizedDescription)
                }
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
            } else {
                if let index = lines.firstIndex(where: { $0.clientMsgId == clientMsgId }) {
                    lines[index].delivery = .failed(error.localizedDescription)
                }
            }
            status = "Send failed: \(error.localizedDescription)"
        }
    }

    func sendMedia(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) async {
        composerMediaTask?.cancel()
        await composerMediaTask?.value
        let operationId = UUID()
        composerMediaOperationId = operationId
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performMediaSend(
                data: data, kind: kind, contentType: contentType, fileName: fileName,
                durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
            )
        }
        composerMediaTask = task
        await task.value
        if composerMediaOperationId == operationId {
            composerMediaTask = nil
            composerMediaOperationId = nil
            activeComposerTransferId = nil
        }
    }

    private func performMediaSend(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64?, width: Int?, height: Int?, thumbnail: Data?
    ) async {
        guard
            let dialogId = activeDialogId,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        let caption = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        let replyToMsgId: Int64?
        if case let .replying(messageId, _) = composerMode {
            replyToMsgId = lines.first(where: { $0.id == messageId })?.msgId
        } else { replyToMsgId = nil }
        let clientMsgId = UUID().uuidString.lowercased()
        let presentation = Self.demoAttachment(
            kind: kind, fileName: fileName, byteSize: Int64(data.count), durationMs: durationMs
        )
        var unpersistedPreparation: PreparedMediaUpload?
        var persistedTransfer: MediaTransferRecord?
        var transferPersisted = false
        do {
            composerMode = .uploading(presentation, progress: 0)
            let prepared = try await mediaEngine.prepare(
                data: data, kind: kind, contentType: contentType, fileName: fileName,
                durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
            )
            unpersistedPreparation = prepared
            try await localStore.insertMediaTransfer(
                prepared: prepared, dialogId: dialogId, clientMsgId: clientMsgId,
                caption: caption, replyToMsgId: replyToMsgId
            )
            transferPersisted = true
            unpersistedPreparation = nil
            guard let transfer = try await localStore.mediaTransfer(id: prepared.transferId) else {
                throw CloudAppModelError.localStoreUnavailable
            }
            persistedTransfer = transfer
            activeComposerTransferId = transfer.transferId
            try await localStore.insertSendingMedia(transfer, senderAccountId: accountId)
            lines.append(Line(
                id: "transfer:\(prepared.transferId)", dialogId: dialogId, msgId: nil,
                clientMsgId: clientMsgId, senderAccountId: accountId, text: caption,
                mine: true, delivery: .sending, timestamp: nil,
                media: transfer.media, transferProgress: 0, transferStage: .preparing
            ))
            draft = ""
            await runMediaTransfer(transfer)
        } catch is CancellationError {
            if let unpersistedPreparation { await mediaEngine.discardPrepared(unpersistedPreparation) }
            if let persistedTransfer, let token = storedSession?.session.token {
                await cancelMediaTransfer(persistedTransfer, token: token)
            }
            composerMode = .text
        } catch {
            if let unpersistedPreparation { await mediaEngine.discardPrepared(unpersistedPreparation) }
            if transferPersisted { scheduleOutboxRetry() }
            composerMode = .text
            status = "Media send failed: \(error.localizedDescription)"
            presentNotice("Could not prepare attachment", message: error.localizedDescription)
        }
    }

    func beginVoiceRecording() async {
        #if DEBUG
        if isDemoMode { beginDemoRecording(); return }
        #endif
        do {
            try await voiceRecorder.start()
            composerMode = .recording(elapsedSeconds: 0)
            recordingTask?.cancel()
            recordingTask = Task { [weak self] in
                while let self, !Task.isCancelled, self.voiceRecorder.isRecording {
                    self.composerMode = .recording(elapsedSeconds: self.voiceRecorder.elapsedSeconds)
                    try? await Task.sleep(for: .milliseconds(250))
                }
            }
        } catch {
            status = error.localizedDescription
            composerMode = .text
            let denied = (error as? VoiceRecorderError) == .permissionDenied
            presentNotice(
                denied ? "Microphone access is off" : "Could not record",
                message: error.localizedDescription,
                opensSettings: denied
            )
        }
    }

    func finishVoiceRecording() async {
        #if DEBUG
        if isDemoMode { finishDemoRecording(); return }
        #endif
        recordingTask?.cancel()
        recordingTask = nil
        do {
            let result = try await voiceRecorder.finish()
            composerMode = .text
            await sendMedia(
                data: result.data, kind: "voice", contentType: "audio/mp4",
                fileName: "Voice message.m4a", durationMs: result.durationMs
            )
        } catch VoiceRecorderError.tooShort {
            status = "Recording canceled"
            composerMode = .text
        } catch {
            status = error.localizedDescription
            composerMode = .text
            presentNotice("Voice message was not sent", message: error.localizedDescription)
        }
    }

    func cancelVoiceRecording() {
        recordingTask?.cancel()
        recordingTask = nil
        voiceRecorder.cancel()
        composerMode = .text
    }

    func thumbnailData(for media: CloudMedia) async -> Data? {
        #if DEBUG
        if isDemoMode { return demoMediaBytes(for: media, thumbnail: true) }
        #endif
        guard let token = storedSession?.session.token else { return nil }
        let state = await mediaEngine.mediaDownloadState(mediaId: media.id, expectedSize: media.byteSize)
        LocalFirstMetrics.cacheResult(hit: state?.hasThumbnail == true, thumbnail: true)
        return try? await mediaEngine.thumbnail(
            media: media,
            token: token,
            localStore: localStore
        )
    }

    func presentationImage(
        for media: CloudMedia,
        variant requestedVariant: MediaPresentationVariant
    ) async -> UIImage? {
        let interval = LocalFirstMetrics.begin("Media ready")
        defer { LocalFirstMetrics.end("Media ready", interval) }
        let variant: MediaPresentationVariant = media.kind == "video"
            && requestedVariant == .bubble720 ? .videoPoster : requestedVariant
        let key = MediaPresentationKey(mediaId: media.id, variant: variant)
        #if DEBUG
        if isDemoMode {
            let demoData = demoMediaBytes(for: media, thumbnail: variant != .screen2048)
            return await MediaPresentationCache.shared.image(for: key) {
                guard let data = demoData else { return nil }
                return await Task.detached(priority: .userInitiated) {
                    SafeMediaImageDecoder.decode(data, maxPixelSize: variant.maximumPixelSize)
                }.value
            }
        }
        #endif

        let engine = mediaEngine
        let store = localStore
        let token = storedSession?.session.token
        return await MediaPresentationCache.shared.image(for: key) {
            let durable = await engine.representation(
                media: media,
                variant: variant,
                localStore: store
            )
            let source: Data?
            if let durable {
                LocalFirstMetrics.presentationCacheTier("encrypted-representation")
                source = durable
            } else {
                guard let token else { return nil }
                switch variant {
                case .bubble720, .videoPoster:
                    if media.hasThumbnail {
                        source = try? await engine.thumbnail(
                            media: media,
                            token: token,
                            localStore: store
                        )
                    } else {
                        let state = await engine.mediaDownloadState(
                            mediaId: media.id,
                            expectedSize: media.byteSize
                        )
                        guard state?.isComplete == true else { return nil }
                        source = try? await engine.data(
                            media: media,
                            token: token,
                            localStore: store,
                            priority: .automatic
                        )
                    }
                case .screen2048:
                    source = try? await engine.data(
                        media: media,
                        token: token,
                        localStore: store,
                        priority: .userInitiated
                    )
                }
            }
            guard let source else { return nil }
            let decoded = await Task.detached(priority: .userInitiated) {
                SafeMediaImageDecoder.decode(source, maxPixelSize: variant.maximumPixelSize)
            }.value
            guard let decoded else { return nil }
            if durable == nil {
                let representation = await Task.detached(priority: .utility) {
                    decoded.image.jpegData(compressionQuality: variant == .screen2048 ? 0.9 : 0.82)
                }.value
                if let representation {
                    await engine.storeRepresentation(
                        representation,
                        media: media,
                        variant: variant,
                        localStore: store
                    )
                }
            }
            return decoded
        }
    }

    func mediaAvailability(
        for media: CloudMedia,
        variant: MediaPresentationVariant
    ) async -> MediaAvailability {
        let key = MediaPresentationKey(mediaId: media.id, variant: variant)
        if MediaPresentationCache.shared.contains(key) { return .decoded }
        if await mediaEngine.representation(media: media, variant: variant, localStore: localStore) != nil {
            return .localRepresentation
        }
        guard let state = await mediaEngine.mediaDownloadState(
            mediaId: media.id,
            expectedSize: media.byteSize
        ) else { return .remote }
        if state.isComplete { return .localComplete }
        if state.cachedBytes > 0 {
            return .partial(progress: min(1, Double(state.cachedBytes) / Double(max(1, media.byteSize))))
        }
        if state.hasThumbnail { return .localRepresentation }
        return .remote
    }

    func mediaData(
        for media: CloudMedia,
        progress: @escaping @Sendable (Double) async -> Void = { _ in }
    ) async throws -> Data {
        #if DEBUG
        if isDemoMode {
            // Staged progress so the viewer's download ring is demonstrable.
            await progress(0.4)
            try? await Task.sleep(for: .milliseconds(220))
            await progress(0.85)
            try? await Task.sleep(for: .milliseconds(180))
            await progress(1)
            return demoMediaBytes(for: media, thumbnail: false) ?? Data()
        }
        #endif
        guard let token = storedSession?.session.token else {
            throw CloudAPIError(status: 401, message: "Sign in required", retryAfter: nil)
        }
        let state = await mediaEngine.mediaDownloadState(mediaId: media.id, expectedSize: media.byteSize)
        LocalFirstMetrics.cacheResult(hit: state?.isComplete == true, thumbnail: false)
        return try await mediaEngine.data(
            media: media,
            token: token,
            localStore: localStore,
            priority: .userInitiated,
            progress: progress
        )
    }

    /// A streaming asset that plays this media progressively (chunk-by-chunk) instead of requiring a
    /// full download first. Returns `nil` until there is a session token. Retain the owner while playing.
    func streamingVideoAsset(for media: CloudMedia) -> StreamingMediaAsset? {
        if let prepared = MediaPresentationCache.shared.takePreparedVideoAsset(mediaId: media.id) {
            return prepared
        }
        guard let token = storedSession?.session.token else { return nil }
        return mediaEngine.makeStreamingAsset(
            media: media,
            token: token,
            localStore: localStore
        )
    }

    private func prewarmStreamingVideoAssetIfLocal(for media: CloudMedia) async {
        guard media.kind == "video",
              !MediaPresentationCache.shared.hasPreparedVideoAsset(mediaId: media.id),
              let token = storedSession?.session.token,
              await mediaEngine.mediaDownloadState(
                mediaId: media.id,
                expectedSize: media.byteSize
              )?.isComplete == true else { return }
        let asset = mediaEngine.makeStreamingAsset(
            media: media,
            token: token,
            localStore: localStore,
            startsAccessImmediately: false
        )
        MediaPresentationCache.shared.storePreparedVideoAsset(asset, mediaId: media.id)
    }

    func temporaryMediaURL(data: Data, fileExtension: String?) async throws -> URL {
        try await mediaEngine.temporaryPreview(data: data, fileExtension: fileExtension)
    }

    func removeTemporaryMediaURL(_ url: URL) async {
        await mediaEngine.removeTemporaryPreview(url)
    }

    private func afterSignIn() async {
        guard storedSession?.session.token != nil, let accountId = storedSession?.session.accountId else { return }
        do {
            guard let restoredStore = try await ensureLocalStore() else {
                throw CloudAppModelError.localStoreUnavailable
            }
            let launchSnapshot = try await restoredStore.loadLaunchSnapshot(accountId: accountId)

            // Publish the complete cached launch state in one main-actor turn.
            pts = launchSnapshot.pts
            acceptObservedDialogs(launchSnapshot.dialogs)
            activeDialogId = nil
            lines = []
            canLoadEarlier = false
            launchPhase = .localReady
            status = "Ready"
            startDialogObservation(accountId: accountId)
            startNetworkObservation()
            startMemoryPressureObservation()
            EncryptedProfilePhotoStore.beginAuthenticatedSession()
            profilePhotoMigrationTask?.cancel()
            profilePhotoMigrationTask = Task.detached(priority: .utility) {
                guard !Task.isCancelled else { return }
                _ = EncryptedProfilePhotoStore.migrateLegacySynchronously(accountId: accountId)
            }
        } catch {
            pts = 0
            status = "Local store unavailable: \(error.localizedDescription)"
            setReplicaSyncState(.localFailure)
            launchPhase = .recoveringStore
            return
        }
        installBackgroundWorkHandlers()
        if let localStore {
            startReplicaIntegrityVerification(store: localStore, accountId: accountId)
        }
    }

    private func startReplicaIntegrityVerification(store: CloudLocalStore, accountId: String) {
        replicaIntegrityTask?.cancel()
        replicaIntegrityTask = Task { [weak self, store] in
            do {
                // Let the cached list and first interaction win disk bandwidth. This check is
                // important, but it is not part of the launch critical path.
                try await Task.sleep(for: .seconds(2))
                try await store.verifyIntegrity()
                try Task.checkCancellation()
            } catch is CancellationError {
                return
            } catch {
                guard let self,
                      self.storedSession?.session.accountId == accountId,
                      let currentStore = self.localStore,
                      currentStore === store
                else { return }
                self.postSignInTask?.cancel()
                self.postSyncWorkTask?.cancel()
                await self.replicaSyncCoordinator.invalidate()
                self.historyHydrationTask?.cancel()
                self.mediaDownloadTask?.cancel()
                self.dialogObservationTask?.cancel()
                self.timelineObservationTask?.cancel()
                await self.hintSocket?.stop()
                self.hintSocket = nil
                await BackgroundRuntimeCoordinator.shared.removeWorkHandlersAndWait()
                self.setReplicaSyncState(.localFailure)
                self.launchPhase = .recoveringStore
                self.status = "Local store integrity check failed; cached files were preserved for recovery"
            }
        }
    }

    func activateForegroundServices() async {
        mediaSchedulerForegrounded = true
        await mediaPrefetchScheduler.update(
            networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
            foregrounded: true
        )
        guard launchPhase == .localReady, storedSession != nil else { return }
        guard postSignInTask == nil else { return }
        postSignInTask = Task { [weak self] in
            guard let self else { return }
            await self.startOnlineServices()
            self.postSignInTask = nil
        }
    }

    func setForegroundActive(_ isActive: Bool) async {
        mediaSchedulerForegrounded = isActive
        await mediaPrefetchScheduler.update(
            networkClass: ReplicaNetworkMonitor.shared.snapshot().networkClass,
            foregrounded: isActive
        )
        if isActive { scheduleMediaDownloadProcessing() }
    }

    private func prepareBackgroundMediaRuntime() async {
        guard
            !backgroundMediaRuntimePrepared,
            launchPhase == .localReady,
            storedSession != nil,
            let localStore
        else { return }
        backgroundMediaRuntimePrepared = true
        do {
            try await mediaEngine.warmCache(localStore: localStore)
        } catch {
            // Media is evictable and must never block the encrypted text replica. Leave this false
            // so the foreground activation or a later background wake can retry initialization.
            backgroundMediaRuntimePrepared = false
        }
    }

    private func ensureLocalStore() async throws -> CloudLocalStore? {
        if let localStore { return localStore }
        guard opensDefaultLocalStore else { return nil }
        let interval = LocalFirstMetrics.begin("Database open")
        defer { LocalFirstMetrics.end("Database open", interval) }
        let store = try await localStoreBootstrapper.openDefaultStore()
        localStore = store
        return store
    }

    private func startOnlineServices() async {
        guard launchPhase == .localReady, storedSession != nil else { return }
        #if DEBUG
        if TelegramFastUITestFixture.enabled {
            setReplicaSyncState(.offline)
            status = "Offline fixture — showing saved chats"
            return
        }
        #endif
        await resume()
        // Registration can prompt, so connection checking must already be in flight. Everything
        // that can compete with opening a cached chat is deferred until the difference pass wins.
        await pushCenter.requestAuthorization()
    }

    #if DEBUG
    private func installTelegramFastUITestFixture() async throws {
        if TelegramFastUITestFixture.resetsStorage {
            try? await tokenStore.clear()
            try TelegramFastUITestFixture.reset()
        }
        let fixtureSession = TelegramFastUITestFixture.session
        try await tokenStore.save(fixtureSession)
        storedSession = fixtureSession
        phone = fixtureSession.phone
        displayName = fixtureSession.displayName
        profileDetails = StoredProfileDetails(
            firstName: "UI",
            lastName: "Fixture",
            bio: "Encrypted offline test profile",
            birthday: nil,
            colorIndex: 3
        )
        guard let store = try await ensureLocalStore() else {
            throw CloudAppModelError.localStoreUnavailable
        }
        try await TelegramFastUITestFixture.install(into: store)
        await afterSignIn()
        setReplicaSyncState(.offline)
        status = "Offline fixture — showing saved chats"
    }
    #endif

    private func installBackgroundWorkHandlers() {
        BackgroundRuntimeCoordinator.shared.installWorkHandlers(
            appRefresh: { [weak self] context in
                guard let self else { return .noData }
                do {
                    try context.checkCancellation()
                    let previousPts = await self.pts
                    await self.syncNow()
                    try context.checkCancellation()
                    await self.retryPendingOutbox()
                    try context.checkCancellation()
                    await self.retryPendingMessageMutations()
                    try context.checkCancellation()
                    await self.retryPendingReadReceipts()
                    return await self.pts > previousPts ? .completed : .noData
                } catch {
                    return .retry
                }
            },
            processing: { [weak self] context in
                guard let self else { return .noData }
                do {
                    try context.checkCancellation()
                    await self.syncNow()
                    try context.checkCancellation()
                    await self.resumeHistoryHydration()
                    try context.checkCancellation()
                    await self.retryPendingReadReceipts()
                    try context.checkCancellation()
                    await self.processMediaDownloadJobs(maximumJobs: 12)
                    try context.checkCancellation()
                    if let localStore = await self.localStore {
                        await self.mediaEngine.enforceCachePolicy(localStore: localStore)
                    } else {
                        await self.mediaEngine.enforceCachePolicy()
                    }
                    try context.checkCancellation()
                    await self.refreshMediaCacheUsage()
                    return .completed
                } catch {
                    return .retry
                }
            }
        )
        BackgroundRuntimeCoordinator.shared.schedulePendingWork()
    }

    private func startDialogObservation(accountId: String) {
        dialogObservationTask?.cancel()
        guard let localStore else { return }
        dialogObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeDialogs(accountId: accountId)
                for try await localDialogs in values {
                    try Task.checkCancellation()
                    guard let self, self.storedSession?.session.accountId == accountId else { return }
                    self.acceptObservedDialogs(localDialogs)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.storedSession?.session.accountId == accountId else { return }
                self.status = "Dialog observation paused: \(error.localizedDescription)"
            }
        }
    }

    private func startTimelineObservation(dialogId: String) {
        timelineObservationTask?.cancel()
        guard let localStore else {
            conversationOpenState = .failedLocal
            conversationOpenStartedAt.removeValue(forKey: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
            return
        }
        timelineObservationTask = Task { [weak self, localStore] in
            do {
                let values = await localStore.observeConversation(dialogId: dialogId, window: .initial)
                for try await snapshot in values {
                    try Task.checkCancellation()
                    guard let self, self.activeDialogId == dialogId else { return }
                    await self.loadLocalLines(dialogId: dialogId, observedSnapshot: snapshot)
                }
            } catch is CancellationError {
                return
            } catch {
                guard let self, self.activeDialogId == dialogId else { return }
                self.conversationOpenState = .failedLocal
                self.status = "Timeline observation paused: \(error.localizedDescription)"
                self.conversationOpenStartedAt.removeValue(forKey: dialogId)
                self.finishConversationOpenWaiters(dialogId: dialogId)
            }
        }
    }

    private func startMemoryPressureObservation() {
        guard memoryPressureTask == nil else { return }
        memoryPressureTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(
                named: UIApplication.didReceiveMemoryWarningNotification
            ) {
                guard let self, !Task.isCancelled else { return }
                self.purgePreparedConversations()
                MediaPresentationCache.shared.removeAll()
            }
        }
    }

    private func acceptObservedDialogs(_ localDialogs: [LocalDialog]) {
        let previous = Dictionary(uniqueKeysWithValues: dialogs.map { ($0.id, $0) })
        dialogs = localDialogs.map { local in
            var resolved = dialog(from: local)
            if let existing = previous[resolved.id] {
                resolved.draftPreview = draftsByDialog[resolved.id].flatMap { draft in
                    let trimmed = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                    return trimmed.isEmpty ? nil : trimmed
                }
                resolved.isPinned = existing.isPinned
                resolved.isMuted = existing.isMuted
                resolved.isArchived = existing.isArchived
                resolved.mentionCount = existing.mentionCount
                resolved.isTyping = existing.isTyping
            }
            return resolved
        }
        sortDialogsForPresentation()
    }

    func updateTimelineViewport(
        dialogId: String,
        visibleLineIds: [String],
        isAtBottom: Bool
    ) {
        guard activeDialogId == dialogId else { return }
        let visibleIds = Set(visibleLineIds)
        let topVisibleMsgId = lines.first(where: { visibleIds.contains($0.id) })?.msgId
        timelineTopVisibleMsgId = isAtBottom ? nil : topVisibleMsgId
        timelineIsAtBottom = isAtBottom

        let visibleMessages = loadedLocalMessages.filter { visibleIds.contains($0.localId) }
        pendingVisibleReadMessages = visibleMessages
        let visibleMedia = visibleMessages.compactMap(\.media)
        if !visibleMedia.isEmpty {
            Task { [weak self] in
                guard let self, self.activeDialogId == dialogId else { return }
                await self.queueMediaDownloads(visibleMedia, dialogId: dialogId, visible: true)
                for media in visibleMedia where media.kind == "video" {
                    await self.prewarmStreamingVideoAssetIfLocal(for: media)
                }
            }
        }
        viewportPersistenceTask?.cancel()
        viewportPersistenceTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(250))
            guard !Task.isCancelled, let self,
                  self.activeDialogId == dialogId,
                  let accountId = self.storedSession?.session.accountId,
                  let localStore = self.localStore else { return }
            let state = ChatViewportState(
                dialogId: dialogId,
                accountId: accountId,
                topVisibleMsgId: topVisibleMsgId,
                wasAtBottom: isAtBottom
            )
            try? await localStore.saveViewportState(state)
            await self.markReadIfNeeded(dialogId: dialogId, messages: visibleMessages)
        }
    }

    private func resumeHistoryHydration() async {
        if let historyHydrationTask {
            await withTaskCancellationHandler {
                await historyHydrationTask.value
            } onCancel: {
                historyHydrationTask.cancel()
            }
            return
        }
        guard let token = storedSession?.session.token, localStore != nil else { return }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.hydrateHistoryPages(token: token)
        }
        historyHydrationTask = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        historyHydrationTask = nil
    }

    private func hydrateHistoryPages(token: String) async {
        let interval = LocalFirstMetrics.begin("History hydration")
        defer { LocalFirstMetrics.end("History hydration", interval) }
        guard let localStore else { return }
        var pagesSinceYield = 0

        while !Task.isCancelled, storedSession?.session.token == token {
            let activeId = activeDialogId
            let unreadIds = Set(dialogs.lazy.filter { $0.unreadCount > 0 }.map(\.id))
            var priorityIds: [String] = []
            if let activeId { priorityIds.append(activeId) }
            priorityIds.append(contentsOf: dialogs.lazy.filter { $0.unreadCount > 0 }.prefix(199).map(\.id))
            let ready: [DialogHistoryState]
            do {
                let general = try await localStore.historyStatesReady(limit: 100)
                let priority = try await localStore.historyStatesReady(dialogIds: priorityIds)
                ready = Array(Dictionary(
                    (general + priority).map { ($0.dialogId, $0) },
                    uniquingKeysWith: { _, newer in newer }
                ).values)
            } catch {
                return
            }
            guard !ready.isEmpty else { return }

            let network = ReplicaNetworkMonitor.shared.snapshot()
            guard network.allowsEssentialSync else { return }
            let recency = Dictionary(uniqueKeysWithValues: dialogs.enumerated().map { ($0.element.id, $0.offset) })
            let eligible = network.allowsDiscretionaryHydration
                ? ready
                : ready.filter { $0.dialogId == activeId || unreadIds.contains($0.dialogId) }
            if eligible.isEmpty {
                BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                return
            }
            let prioritized = eligible.sorted { lhs, rhs in
                let lhsTier = lhs.dialogId == activeId ? 0 : (unreadIds.contains(lhs.dialogId) ? 1 : 2)
                let rhsTier = rhs.dialogId == activeId ? 0 : (unreadIds.contains(rhs.dialogId) ? 1 : 2)
                if lhsTier != rhsTier { return lhsTier < rhsTier }
                return (recency[lhs.dialogId] ?? .max) < (recency[rhs.dialogId] ?? .max)
            }

            var madeProgress = false
            for state in prioritized {
                if Task.isCancelled || storedSession?.session.token != token { return }
                let beforeMsgId = state.nextBeforeMsgId ?? max(1, state.ceilingMsgId + 1)
                do {
                    let page = try await api.getHistory(
                        dialogId: state.dialogId,
                        beforeMsgId: beforeMsgId,
                        limit: 100,
                        token: token
                    )
                    try await localStore.applyHistoryPage(page)
                    pagesSinceYield += 1
                    madeProgress = true
                } catch is CancellationError {
                    return
                } catch {
                    let delay = retryDelay(forRetryCount: state.retryCount + 1)
                    try? await localStore.markHistoryHydrationFailed(
                        dialogId: state.dialogId,
                        retryAfter: delay
                    )
                    BackgroundRuntimeCoordinator.shared.scheduleProcessing()
                    BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                        earliestBeginDate: Date(timeIntervalSinceNow: delay)
                    )
                    if case .authenticationRequired = cloudFailureDisposition(error) { return }
                }
            }
            if !madeProgress { break }
            // Keep long backfills cooperative without imposing a global page cap. The persisted
            // cursor makes every yield/termination resumable.
            if pagesSinceYield >= 24 {
                pagesSinceYield = 0
                await Task.yield()
            }
        }

        if !Task.isCancelled,
           (try? await localStore.historyStatesReady(limit: 1).isEmpty) == false {
            BackgroundRuntimeCoordinator.shared.scheduleProcessing()
        }
    }

    private func refreshServerCapabilities() async {
        do {
            let response = try await api.capabilities()
            var resolved: MessagingCapabilities = []
            let advertised = Set(response.capabilities)
            if advertised.contains("core_text") || advertised.contains("replies") {
                resolved.insert(.replies)
            }
            if advertised.contains("message_mutations") {
                resolved.formUnion([.editing, .deletion])
            }
            if advertised.contains("reactions") { resolved.insert(.reactions) }
            if advertised.contains("forwarding") { resolved.insert(.forwarding) }
            if advertised.contains("media_uploads") { resolved.insert(.media) }
            if advertised.contains("media_multipart_v2"), resolved.contains(.media) {
                resolved.insert(.multipartMedia)
            }
            if advertised.contains("voice_notes"), resolved.contains(.media) {
                resolved.insert(.voiceNotes)
            }
            if advertised.contains("profiles") { resolved.insert(.profiles) }
            negotiatedCapabilities = resolved
            capabilityDefaults.set(Int(resolved.rawValue), forKey: capabilityCacheKey)
        } catch let error as CloudAPIError where error.status == 404 {
            negotiatedCapabilities = [.replies]
            capabilityDefaults.set(Int(MessagingCapabilities.replies.rawValue), forKey: capabilityCacheKey)
        } catch {
            // Keep the last successfully negotiated set when the server cannot be reached.
        }
    }

    private func setReplicaSyncState(_ state: ReplicaSyncState) {
        replicaSyncState = state
        switch state {
        case .checking:
            replicaConnectivityState = .checking
            replicaUpdatePhase = .checkingRemoteState
            connectionViewState = .connecting
        case .updating:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .catchingUp(appliedBatches: appliedSyncBatches)
            connectionViewState = .connecting
        case .ready:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .upToDate
            connectionViewState = .live
        case .offline:
            replicaConnectivityState = .offline
            replicaUpdatePhase = .idle
            connectionViewState = .offline
        case .connectionSlow:
            replicaConnectivityState = .checking
            replicaUpdatePhase = .stalled(reason: .slowConnection)
            connectionViewState = .connecting
        case .serverUnavailable:
            replicaConnectivityState = .serverUnavailable
            replicaUpdatePhase = .stalled(reason: .serverUnavailable)
            connectionViewState = .connecting
        case .sessionExpired:
            replicaConnectivityState = .sessionExpired
            replicaUpdatePhase = .idle
            connectionViewState = .connecting
        case .protocolFailure:
            replicaConnectivityState = .reachable
            replicaUpdatePhase = .stalled(reason: .protocolFailure)
            connectionViewState = .connecting
        case .localFailure:
            replicaUpdatePhase = .stalled(reason: .localReplicaFailure)
            connectionViewState = .connecting
        case .configurationError:
            replicaConnectivityState = .configurationError
            replicaUpdatePhase = .stalled(reason: .configuration)
            connectionViewState = .connecting
        }
    }

    private func startNetworkObservation() {
        networkObservationTask?.cancel()
        networkObservationTask = Task { [weak self] in
            var previous = ReplicaNetworkClass.unknown
            for await snapshot in ReplicaNetworkMonitor.shared.updates() {
                guard let self, !Task.isCancelled else { return }
                await self.mediaPrefetchScheduler.update(
                    networkClass: snapshot.networkClass,
                    foregrounded: self.mediaSchedulerForegrounded
                )
                let recovered = previous == .offline && snapshot.networkClass != .offline
                previous = snapshot.networkClass
                if snapshot.networkClass == .offline {
                    self.setReplicaSyncState(.offline)
                    self.status = "Offline. Showing saved messages."
                    continue
                }
                guard recovered else { continue }
                try? await Task.sleep(for: .milliseconds(500))
                guard !Task.isCancelled,
                      ReplicaNetworkMonitor.shared.snapshot().networkClass != .offline else { continue }
                await self.replicaSyncCoordinator.trigger(.pathRecovery)
                self.scheduleMediaDownloadProcessing()
                await self.resumeHistoryHydration()
            }
        }
    }

    nonisolated static func replicaFailureState(
        for error: Error,
        network: ReplicaNetworkSnapshot
    ) -> ReplicaSyncState {
        if error is CancellationError || (error as? URLError)?.code == .cancelled {
            return .checking
        }
        if network.networkClass == .offline { return .offline }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .notConnectedToInternet, .internationalRoamingOff, .dataNotAllowed:
                return .offline
            case .timedOut:
                return .connectionSlow
            case .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .networkConnectionLost, .badServerResponse:
                return .serverUnavailable
            default:
                return .serverUnavailable
            }
        }
        if let apiError = error as? CloudAPIError {
            switch apiError.status {
            case 401, 403: return .sessionExpired
            case 408, 429, 500...599: return .serverUnavailable
            default: return .protocolFailure
            }
        }
        if error is DecodingError { return .protocolFailure }
        return .localFailure
    }

    private func publishTransportFailure(_ error: Error) {
        let failure = Self.replicaFailureState(
            for: error,
            network: ReplicaNetworkMonitor.shared.snapshot()
        )
        switch failure {
        case .offline, .connectionSlow, .serverUnavailable, .sessionExpired:
            setReplicaSyncState(failure)
        case .checking, .updating, .ready, .protocolFailure, .localFailure, .configurationError:
            break
        }
    }

    private func presentNotice(_ title: String, message: String, opensSettings: Bool = false) {
        operationNotice = Notice(title: title, message: message, opensSettings: opensSettings)
    }

    private func uploadPushToken(_ deviceToken: String, environment: String) async {
        guard let token = storedSession?.session.token else { return }
        let registration = "\(environment):\(deviceToken)"
        guard uploadedPushRegistration != registration else { return }
        do {
            _ = try await api.registerPushToken(deviceToken, environment: environment, token: token)
            guard storedSession?.session.token == token else {
                // Registration and sign-out can overlap at an await point. If sign-out won the
                // race, undo this late registration so the signed-out device receives no alerts.
                _ = try? await api.unregisterPushToken(token: token)
                return
            }
            uploadedPushRegistration = registration
        } catch {
            // Token registration is retried when APNs rotates the token or on the next app launch.
            status = "Push registration failed: \(error.localizedDescription)"
        }
    }

    private func syncFromPush() async -> Bool {
        let previousPts = pts
        _ = await syncNow()
        return pts > previousPts
    }

    func resume() async {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard storedSession?.session.token != nil else { return }
        setReplicaSyncState(.checking)
        status = "Checking connection"
        pushCenter.refreshRegistration()
        scheduleSync(trigger: .foreground)
    }

    func retryReplicaSync() {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard launchPhase == .localReady, storedSession?.session.token != nil else { return }
        setReplicaSyncState(.checking)
        status = "Checking connection"
        scheduleSync(trigger: .manualRetry)
    }

    private func startHints(token: String) async {
        hintTask?.cancel()
        await hintSocket?.stop()

        let socket = CloudHintSocket(url: api.config.wsURL(), token: token)
        hintSocket = socket
        hintTask = Task { [weak self, socket] in
            await socket.start()
            await withTaskGroup(of: Void.self) { group in
                group.addTask { [weak self, socket] in
                    for await _ in socket.hints {
                        guard let self, !Task.isCancelled else { return }
                        await self.replicaSyncCoordinator.trigger(.hint)
                    }
                }
                group.addTask { [weak self, socket] in
                    var hasConnected = false
                    for await state in socket.states {
                        guard let self, !Task.isCancelled else { return }
                        guard state == .connected else { continue }
                        if hasConnected {
                            await self.replicaSyncCoordinator.trigger(.socketReconnect)
                        }
                        hasConnected = true
                    }
                }
                await group.waitForAll()
            }
        }
    }

    private func scheduleSync(trigger: ReplicaSyncTrigger = .hint) {
        Task { [replicaSyncCoordinator] in
            await replicaSyncCoordinator.trigger(trigger)
        }
    }

    private func runForegroundSyncAttempt(generation: UInt64) async {
        guard let token = storedSession?.session.token else { return }
        if let issue = api.config.validationIssue() {
            setReplicaSyncState(.configurationError)
            status = issue.message
            return
        }
        let initialNetwork = ReplicaNetworkMonitor.shared.snapshot()
        if initialNetwork.networkClass == .offline {
            setReplicaSyncState(.offline)
            status = "Offline. Showing saved messages."
            return
        }
        let api = api
        let timeout = Self.foregroundSyncTimeoutSeconds
        let probeInterval = LocalFirstMetrics.begin("Sync probe")
        let deadline = await ReplicaDeadline.run(for: .seconds(timeout)) { [api, token, initialNetwork] in
            do {
                let state = try await api.getState(token: token)
                try Task.checkCancellation()
                return ReplicaStateProbeOutcome.succeeded(state)
            } catch is CancellationError {
                return .cancelled
            } catch {
                return .failed(Self.replicaFailureState(for: error, network: initialNetwork))
            }
        }
        let outcome: ReplicaStateProbeOutcome = switch deadline {
        case .value(let value): value
        case .timedOut: .timedOut
        case .cancelled: .cancelled
        }
        LocalFirstMetrics.end("Sync probe", probeInterval)

        guard await replicaSyncCoordinator.isCurrent(generation),
              storedSession?.session.token == token else { return }
        switch outcome {
        case .succeeded(let remoteState):
            lastSuccessfulServerContact = Date()
            if remoteState.pts < pts {
                setReplicaSyncState(.protocolFailure)
                status = "Server update state moved backwards. Showing saved messages."
                return
            }
            let replicaInitialized = if let localStore,
                                        let accountId = storedSession?.session.accountId {
                (try? await localStore.isReplicaInitialized(accountId: accountId)) == true
            } else {
                false
            }
            guard await replicaSyncCoordinator.isCurrent(generation),
                  storedSession?.session.token == token else { return }
            if replicaInitialized, remoteState.pts == pts {
                setReplicaSyncState(.ready)
                status = "Chats are up to date"
                await startHints(token: token)
                schedulePostSyncWork(token: token)
                return
            }
            appliedSyncBatches = 0
            lastForegroundSyncFailure = nil
            await markReplicaUpdating(generation: generation, token: token)
            let succeeded = await syncNow(publishesConnectionState: false)
            guard await replicaSyncCoordinator.isCurrent(generation),
                  storedSession?.session.token == token,
                  !Task.isCancelled else { return }
            guard succeeded else {
                let failure = lastForegroundSyncFailure ?? .serverUnavailable
                setReplicaSyncState(failure)
                status = failure.title
                return
            }
            setReplicaSyncState(.ready)
            status = "Chats are up to date"
            await startHints(token: token)
            schedulePostSyncWork(token: token)
        case .failed(let failure):
            setReplicaSyncState(failure)
            status = failure.title
        case .timedOut:
            setReplicaSyncState(.connectionSlow)
            status = "Connection is slow. Showing saved messages."
        case .cancelled:
            return
        }
    }

    private func markReplicaUpdating(generation: UInt64, token: String) async {
        guard await replicaSyncCoordinator.isCurrent(generation),
              storedSession?.session.token == token else { return }
        setReplicaSyncState(.updating)
        status = "Updating chats"
    }

    private func stopHints() async {
        hintTask?.cancel()
        hintTask = nil
        await hintSocket?.stop()
        hintSocket = nil
    }

    private func schedulePostSyncWork(token: String) {
        postSyncWorkTask?.cancel()
        postSyncWorkTask = Task(priority: .utility) { [weak self] in
            do {
                // Let the freshly updated list and the user's first chat tap get main-thread and
                // SQLCipher priority before discretionary reconciliation starts.
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            guard let self, self.storedSession?.session.token == token else { return }
            await self.refreshServerCapabilities()
            self.reconcileProfileWithServer()
            await self.refreshMediaCacheUsage()
            await self.loadMediaPolicies()
            await self.retryPendingMessageMutations()
            await self.retryPendingReadReceipts()
            await self.retryMediaTransfers()
            self.scheduleMediaDownloadProcessing()
            self.scheduleOutboxRetry()
            await self.resumeHistoryHydration()
            if self.storedSession?.session.token == token {
                self.postSyncWorkTask = nil
            }
        }
    }

    private func scheduleOutboxRetry(after delay: TimeInterval = 0) {
        guard retryTask == nil else { return }
        retryTask = Task { [weak self] in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                if Task.isCancelled { return }
            }

            await self?.retryPendingOutbox()
            let nextDelay = await self?.nextOutboxRetryDelay()
            await MainActor.run {
                self?.retryTask = nil
            }
            if let nextDelay {
                await MainActor.run {
                    self?.scheduleOutboxRetry(after: nextDelay)
                }
            }
        }
    }

    @discardableResult
    private func syncNow(publishesConnectionState: Bool = true) async -> Bool {
        let syncInterval = LocalFirstMetrics.begin("Difference sync")
        defer { LocalFirstMetrics.end("Difference sync", syncInterval) }
        guard let token = storedSession?.session.token else { return false }
        if syncInFlight {
            syncAgain = true
            return false
        }

        syncInFlight = true
        defer { syncInFlight = false }

        repeat {
            syncAgain = false
            do {
                if let localStore,
                   let accountId = storedSession?.session.accountId,
                   !(try await localStore.isReplicaInitialized(accountId: accountId)) {
                    // A new device has no meaningful difference cursor yet. Bootstrap first even
                    // when the server could technically return a small difference from PTS zero.
                    // Returning devices skip this path and render their encrypted replica instantly.
                    try await rebuildLocalReplica(token: token)
                }
                var response = try await fetchDifferencePage(token: token)
                while true {
                    if response.kind == "difference_too_long" {
                        try await rebuildLocalReplica(token: token)
                        response = try await fetchDifferencePage(token: token)
                        continue
                    }
                    try await applyDifferencePage(response)
                    pts = response.state.pts
                    appliedSyncBatches += 1
                    if !publishesConnectionState {
                        setReplicaSyncState(.updating)
                    }
                    if response.kind != "difference_slice" { break }
                    response = try await fetchDifferencePage(token: token)
                }
                if publishesConnectionState {
                    setReplicaSyncState(.ready)
                    status = "Chats are up to date"
                    schedulePostSyncWork(token: token)
                }
            } catch {
                if Task.isCancelled
                    || (error as? URLError)?.code == .cancelled {
                    return false
                }
                status = "Sync failed: \(error.localizedDescription)"
                let failure = Self.replicaFailureState(
                    for: error,
                    network: ReplicaNetworkMonitor.shared.snapshot()
                )
                lastForegroundSyncFailure = failure
                if publishesConnectionState {
                    setReplicaSyncState(failure)
                }
                return false
            }
        } while syncAgain
        return true
    }

    private func fetchDifferencePage(token: String) async throws -> DifferenceResponse {
        let interval = LocalFirstMetrics.begin("Sync difference page")
        defer { LocalFirstMetrics.end("Sync difference page", interval) }
        let limits = Self.differenceRequestLimits(
            for: ReplicaNetworkMonitor.shared.snapshot()
        )
        return try await api.getDifference(
            sincePts: pts,
            maxEvents: limits.maxEvents,
            maxBytes: limits.maxBytes,
            token: token
        )
    }

    private func applyDifferencePage(_ response: DifferenceResponse) async throws {
        let interval = LocalFirstMetrics.begin("Sync apply page")
        defer { LocalFirstMetrics.end("Sync apply page", interval) }
        try await apply(response)
    }

    nonisolated static func differenceRequestLimits(
        for network: ReplicaNetworkSnapshot
    ) -> (maxEvents: Int, maxBytes: Int) {
        switch network.networkClass {
        case .wifi:
            (200, 256 * 1_024)
        case .cellular:
            (100, 128 * 1_024)
        case .unknown, .offline, .constrained, .roaming:
            (50, 64 * 1_024)
        }
    }

    private func apply(_ difference: DifferenceResponse) async throws {
        if difference.kind == "difference_too_long" {
            throw CloudAppModelError.bootstrapRequired
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            try await localStore.applyDifference(difference, accountId: accountId)
            if !profileDetails.needsServerSync,
               let token = storedSession?.session.token,
               let ownProfile = (difference.updates ?? []).reversed().compactMap({ update in
                   Self.cloudProfile(from: update, ownAccountId: accountId)
               }).first {
                await acceptCanonicalProfile(ownProfile, token: token)
            }
            // Dialog and active-timeline observations publish this transaction once. Explicitly
            // querying both again here caused online-only reload storms during chat opening.
        } else {
            for update in difference.updates ?? [] {
                guard ["message.new", "message.edited", "message.deleted", "reaction.updated"].contains(update.type),
                      let message = update.message else { continue }
                upsert(message)
            }
        }
    }

    private func rebuildLocalReplica(token: String) async throws {
        guard let accountId = storedSession?.session.accountId else { return }
        guard let localStore else {
            throw CloudAppModelError.localStoreUnavailable
        }

        status = "Rebuilding local cache"
        func downloadPages(bootstrapToken: String, startingAt initialCursor: String?) async throws {
            var cursor = initialCursor
            while true {
                try Task.checkCancellation()
                let page = try await api.getBootstrapDialogs(
                    bootstrapToken: bootstrapToken,
                    cursor: cursor,
                    limit: 20,
                    previewMessages: 5,
                    token: token
                )
                try await localStore.applyBootstrapPage(page)
                guard page.hasMore else { return }
                guard let nextCursor = page.nextCursor else {
                    throw CloudAppModelError.invalidBootstrapCursor
                }
                cursor = nextCursor
            }
        }

        var bootstrapToken: String
        var snapshotPts: Int64
        var startingCursor: String?
        let savedState = try await localStore.loadBootstrapState(accountId: accountId)
        let hasPublishedDialogs = try await localStore.latestDialogId() != nil
        let bootstrapMode = savedState?.mode ?? (hasPublishedDialogs ? .replacement : .initial)
        if let saved = savedState,
           saved.status == "in_progress", let savedToken = saved.token {
            bootstrapToken = savedToken
            snapshotPts = saved.snapshotPts
            startingCursor = saved.nextCursor
        } else {
            let bootstrap = try await api.startBootstrap(token: token)
            bootstrapToken = bootstrap.token
            snapshotPts = bootstrap.state.pts
            startingCursor = nil
            try await localStore.beginBootstrap(
                accountId: accountId,
                token: bootstrapToken,
                snapshotPts: snapshotPts,
                mode: bootstrapMode
            )
        }

        do {
            try await downloadPages(bootstrapToken: bootstrapToken, startingAt: startingCursor)
        } catch let error as CloudAPIError
            where error.status == 400 && error.message.localizedCaseInsensitiveContains("bootstrap") {
            let bootstrap = try await api.startBootstrap(token: token)
            bootstrapToken = bootstrap.token
            snapshotPts = bootstrap.state.pts
            startingCursor = nil
            try await localStore.beginBootstrap(
                accountId: accountId,
                token: bootstrapToken,
                snapshotPts: snapshotPts,
                mode: bootstrapMode
            )
            try await downloadPages(bootstrapToken: bootstrapToken, startingAt: nil)
        }

        try await localStore.finishBootstrap(accountId: accountId, pts: snapshotPts)
        pts = snapshotPts
        BackgroundRuntimeCoordinator.shared.scheduleProcessing()
    }

    private func refreshDialogs() async {
        let interval = LocalFirstMetrics.begin("Dialog query")
        defer { LocalFirstMetrics.end("Dialog query", interval) }
        guard let localStore, let accountId = storedSession?.session.accountId else { return }
        do {
            let localDialogs = try await localStore.dialogs(accountId: accountId)
            acceptObservedDialogs(localDialogs)
        } catch {
            status = "Dialog load failed: \(error.localizedDescription)"
        }
    }

    private func cacheCurrentLines(for dialogId: String) {
        cachedLinesByDialog[dialogId] = lines
        cachedLocalMessagesByDialog[dialogId] = loadedLocalMessages
        cachedConversationCostByDialog[dialogId] = Self.preparedConversationCost(
            lines: lines,
            messages: loadedLocalMessages
        )
        cachedLineDialogOrder.removeAll { $0 == dialogId }
        cachedLineDialogOrder.append(dialogId)
        while cachedLineDialogOrder.count > 12
            || cachedConversationCostByDialog.values.reduce(0, +) > 8 * 1_024 * 1_024 {
            let evicted = cachedLineDialogOrder.removeFirst()
            cachedLinesByDialog.removeValue(forKey: evicted)
            cachedLocalMessagesByDialog.removeValue(forKey: evicted)
            cachedConversationCostByDialog.removeValue(forKey: evicted)
        }
    }

    private func purgePreparedConversations() {
        guard let activeDialogId,
              let activeLines = cachedLinesByDialog[activeDialogId],
              let activeMessages = cachedLocalMessagesByDialog[activeDialogId] else {
            cachedLinesByDialog.removeAll(keepingCapacity: true)
            cachedLocalMessagesByDialog.removeAll(keepingCapacity: true)
            cachedLineDialogOrder.removeAll(keepingCapacity: true)
            cachedConversationCostByDialog.removeAll(keepingCapacity: true)
            return
        }
        cachedLinesByDialog = [activeDialogId: activeLines]
        cachedLocalMessagesByDialog = [activeDialogId: activeMessages]
        cachedLineDialogOrder = [activeDialogId]
        cachedConversationCostByDialog = [
            activeDialogId: Self.preparedConversationCost(lines: activeLines, messages: activeMessages)
        ]
    }

    nonisolated private static func preparedConversationCost(
        lines: [Line],
        messages: [LocalMessage]
    ) -> Int {
        let lineStrings = lines.reduce(0) {
            $0 + $1.text.utf8.count + ($1.replyPreview?.utf8.count ?? 0) + 192
        }
        let messageStrings = messages.reduce(0) {
            $0 + $1.text.utf8.count + $1.clientMsgId.utf8.count + 160
        }
        return lineStrings + messageStrings
    }

    private func loadLocalLines(
        dialogId: String,
        observedSnapshot: ConversationLocalSnapshot? = nil
    ) async {
        let timelineInterval = LocalFirstMetrics.begin("Timeline query")
        defer { LocalFirstMetrics.end("Timeline query", timelineInterval) }
        guard let localStore, activeDialogId == dialogId else { return }
        timelineLoadGeneration &+= 1
        let loadGeneration = timelineLoadGeneration
        let selectionGeneration = dialogSelectionGeneration
        do {
            let conversationSnapshot: ConversationLocalSnapshot
            let centeredAnchorMsgId = timelineIsAtBottom ? nil : timelineTopVisibleMsgId
            if let observedSnapshot, centeredAnchorMsgId == nil {
                conversationSnapshot = observedSnapshot
            } else if let anchorMsgId = centeredAnchorMsgId {
                let base = try await localStore.conversationSnapshot(
                    dialogId: dialogId,
                    window: .initial
                )
                let centeredTimeline = try await localStore.timelineWindow(
                    dialogId: dialogId,
                    anchorMsgId: anchorMsgId,
                    beforeCount: timelineBeforeCount,
                    afterCount: timelineAfterCount
                )
                conversationSnapshot = ConversationLocalSnapshot(
                    timeline: centeredTimeline,
                    mutations: base.mutations,
                    transfers: base.transfers,
                    peerReadMsgId: base.peerReadMsgId,
                    historyState: base.historyState
                )
            } else {
                conversationSnapshot = try await localStore.conversationSnapshot(
                    dialogId: dialogId,
                    window: .initial
                )
            }
            let snapshot = conversationSnapshot.timeline
            // Sparse bootstrap previews can sit thousands of IDs ahead of a hydrated unread page.
            // Never render that hole as if the rows were adjacent; expose only the contiguous run
            // around the semantic anchor and let `loadLater` fill the missing keyset pages.
            let messages = centeredAnchorMsgId.map {
                Self.contiguousTimelineSlice(snapshot.messages, anchorMsgId: $0)
            } ?? snapshot.messages
            let rawOldest = snapshot.messages.compactMap(\.msgId).min()
            let rawNewest = snapshot.messages.compactMap(\.msgId).max()
            let displayOldest = messages.compactMap(\.msgId).min()
            let displayNewest = messages.compactMap(\.msgId).max()
            let trimmedEarlierRows = rawOldest != nil && rawOldest != displayOldest
            let trimmedLaterRows = rawNewest != nil && rawNewest != displayNewest
            let mutations = conversationSnapshot.mutations
            let transfers = conversationSnapshot.transfers
            let transfersByClientMessage = Dictionary(
                transfers.map { ($0.clientMsgId, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let mutationsByMessage = Dictionary(
                mutations.map { ($0.msgId, $0) },
                uniquingKeysWith: { _, newer in newer }
            )
            let peerReadMsgId = conversationSnapshot.peerReadMsgId
            let messagesById = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
                message.msgId.map { ($0, message) }
            })
            var preparedLines = messages.compactMap { message -> Line? in
                let mutation = message.msgId.flatMap { mutationsByMessage[$0] }
                guard Self.shouldDisplayInTimeline(
                    messageState: message.state,
                    pendingMutationOperation: mutation?.operation
                ) else { return nil }
                let replyPreview = message.replyToMsgId.map { targetId in
                    guard let target = messagesById[targetId] else { return String(localized: "Earlier message") }
                    return target.state == "deleted_for_all" ? String(localized: "Earlier message") : target.text
                }
                return line(
                    from: message,
                    peerReadMsgId: peerReadMsgId,
                    replyPreview: replyPreview,
                    mutation: mutation,
                    mediaTransfer: transfersByClientMessage[message.clientMsgId]
                )
            }
            let presentationInputs = preparedLines.map {
                TimelinePresentationInput(id: $0.id, mine: $0.mine, timestamp: $0.timestamp)
            }
            let presentation = await Task.detached(priority: .userInitiated) {
                TimelinePresentationBuilder.build(presentationInputs)
            }.value
            let presentationByID = Dictionary(uniqueKeysWithValues: presentation.map { ($0.id, $0) })
            for index in preparedLines.indices {
                guard let metadata = presentationByID[preparedLines[index].id] else { continue }
                preparedLines[index].presentationDayLabel = metadata.dayLabel
                preparedLines[index].presentationTimestampLabel = metadata.timestampLabel
                preparedLines[index].presentationMediaTimestampLabel = metadata.mediaTimestampLabel
                preparedLines[index].presentationIsFirstInGroup = metadata.isFirstInGroup
                preparedLines[index].presentationIsLastInGroup = metadata.isLastInGroup
            }
            let historyState = conversationSnapshot.historyState
            guard activeDialogId == dialogId,
                  dialogSelectionGeneration == selectionGeneration,
                  timelineLoadGeneration == loadGeneration else { return }

            loadedLocalMessages = messages
            lines = preparedLines
            conversationOpenState = preparedLines.isEmpty ? .empty : .ready
            recordConversationLocalReady(dialogId: dialogId)
            canLoadLater = snapshot.hasLaterLocalMessages
                || trimmedLaterRows
                || timelineHasMoreForwardByDialog[dialogId] == true
            canLoadEarlier = snapshot.hasEarlierLocalMessages
                || trimmedEarlierRows
                || historyState.map { !$0.historyComplete } == true
                || (snapshot.oldestServerMsgId != nil && historyState == nil)
            cacheCurrentLines(for: dialogId)
            finishConversationOpenWaiters(dialogId: dialogId)
        } catch {
            if activeDialogId == dialogId,
               dialogSelectionGeneration == selectionGeneration,
               timelineLoadGeneration == loadGeneration {
                conversationOpenState = .failedLocal
                status = "Local load failed: \(error.localizedDescription)"
                conversationOpenStartedAt.removeValue(forKey: dialogId)
                finishConversationOpenWaiters(dialogId: dialogId)
            }
        }
    }

    private func finishConversationOpenWaiters(dialogId: String) {
        let waiters = conversationOpenWaiters.removeValue(forKey: dialogId) ?? []
        waiters.forEach { $0.resume() }
    }

    private func recordConversationLocalReady(dialogId: String) {
        guard let startedAt = conversationOpenStartedAt.removeValue(forKey: dialogId) else { return }
        LocalFirstMetrics.duration("Chat tap to local snapshot", since: startedAt)
    }

    nonisolated static func shouldDisplayInTimeline(
        messageState: String,
        pendingMutationOperation: String?
    ) -> Bool {
        messageState != "deleted_for_all" && pendingMutationOperation != "delete"
    }

    nonisolated static func contiguousTimelineSlice(
        _ messages: [LocalMessage],
        anchorMsgId: Int64
    ) -> [LocalMessage] {
        guard let anchorIndex = messages.firstIndex(where: { $0.msgId == anchorMsgId }) else {
            return messages
        }
        var lowerBound = anchorIndex
        while lowerBound > messages.startIndex {
            let previousIndex = messages.index(before: lowerBound)
            guard let previous = messages[previousIndex].msgId,
                  let current = messages[lowerBound].msgId,
                  previous + 1 == current else { break }
            lowerBound = previousIndex
        }
        var upperBound = anchorIndex
        while upperBound < messages.index(before: messages.endIndex) {
            let nextIndex = messages.index(after: upperBound)
            guard let current = messages[upperBound].msgId,
                  let next = messages[nextIndex].msgId,
                  current + 1 == next else { break }
            upperBound = nextIndex
        }
        return Array(messages[lowerBound...upperBound])
    }

    private func line(
        from message: LocalMessage,
        peerReadMsgId: Int64,
        replyPreview: String?,
        mutation: PendingMessageMutation? = nil,
        mediaTransfer: MediaTransferRecord? = nil
    ) -> Line {
        let mine = message.senderAccountId == storedSession?.session.accountId
        let deliveryState: Line.Delivery
        if let mediaTransfer, mediaTransfer.terminal {
            deliveryState = .failed(mediaTransfer.lastError ?? String(localized: "Attachment failed"))
        } else if mutation != nil {
            deliveryState = .sending
        } else if mine, let msgId = message.msgId, msgId <= peerReadMsgId {
            deliveryState = .seen
        } else {
            deliveryState = delivery(from: message.localState)
        }
        var reactions = message.reactions
        if mutation?.operation == "reaction", let accountId = storedSession?.session.accountId {
            reactions.removeAll { $0.accountId == accountId }
            if let emoji = mutation?.emoji {
                reactions.append(CloudReaction(accountId: accountId, emoji: emoji))
            }
        }
        let presentedText: String
        if mutation?.operation == "edit", let body = mutation?.body {
            presentedText = body
        } else {
            presentedText = message.text
        }
        return Line(
            id: message.localId,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            senderAccountId: message.senderAccountId,
            text: presentedText,
            mine: mine,
            delivery: deliveryState,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            replyPreview: replyPreview,
            reactions: Self.reactionBadges(reactions),
            myReaction: reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji,
            forwardedFromAccountId: message.forwardedFromAccountId,
            forwardedFromDialogId: message.forwardedFromDialogId,
            forwardedFromMsgId: message.forwardedFromMsgId,
            isForwarded: message.isForwarded,
            editVersion: message.editVersion,
            isEdited: (message.editVersion > 0 || mutation?.operation == "edit") && message.state == "visible",
            isDeleted: message.state == "deleted_for_all",
            media: message.media,
            transferProgress: mediaTransfer.map {
                $0.state == "ready_to_send" ? 1 : Double($0.uploadOffset) / Double(max(1, $0.byteSize))
            },
            transferStage: mediaTransfer.map {
                if $0.state == "ready_to_send" { return .finalizing }
                if $0.retryCount > 0 || $0.lastError != nil { return .retrying }
                if $0.uploadOffset == 0 { return .preparing }
                return .uploading
            },
            transferError: mediaTransfer?.lastError,
            pendingMutation: mutation
        )
    }

    private func dialog(from local: LocalDialog) -> Dialog {
        let title = displayTitle(local.title, fallback: shortDialogId(local.dialogId))
        let lastText = local.lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let previewKind = ChatListPreviewKind(messageKind: local.lastKind)
        let subtitle: String
        if let lastText, !lastText.isEmpty {
            subtitle = lastText
        } else if local.lastState == "visible" {
            subtitle = previewKind.title.isEmpty ? String(localized: "Attachment") : previewKind.title
        } else {
            subtitle = "No messages yet"
        }
        return Dialog(
            id: local.dialogId,
            title: title,
            subtitle: subtitle,
            updatedAt: local.lastServerTs ?? local.updatedAt,
            isPending: local.lastLocalState == "sending",
            unreadCount: local.unreadCount,
            previewKind: previewKind,
            lastMessageMine: local.lastSenderAccountId == storedSession?.session.accountId,
            peerAccountId: local.peerAccountId,
            peerBio: local.peerBio,
            peerBirthday: local.peerBirthday,
            profileColorIndex: local.peerColorIndex
        )
    }

    private func displayTitle(_ candidate: String?, fallback: String) -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
    }

    private static func profileDetails(from displayName: String) -> StoredProfileDetails {
        let parts = displayName
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .split(whereSeparator: \.isWhitespace)
            .map(String.init)
        return StoredProfileDetails(
            firstName: parts.first ?? "",
            lastName: parts.dropFirst().joined(separator: " "),
            bio: "",
            birthday: nil,
            colorIndex: 0
        )
    }

    private static func profileDetails(
        from profile: CloudProfile,
        pendingSync: Bool
    ) -> StoredProfileDetails {
        StoredProfileDetails(
            firstName: profile.firstName,
            lastName: profile.lastName,
            bio: profile.bio,
            birthday: profile.birthday.flatMap(profileDate),
            colorIndex: profile.colorIndex,
            serverUpdatedAt: profile.updatedAt,
            pendingSync: pendingSync
        )
    }

    private static func profileDate(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: value)
    }

    private static func cloudProfile(from contact: ContactLookupResponse) -> CloudProfile? {
        guard
            let accountId = contact.accountId,
            let firstName = contact.firstName,
            let lastName = contact.lastName,
            let displayName = contact.displayName,
            let bio = contact.bio,
            let colorIndex = contact.colorIndex,
            let updatedAt = contact.updatedAt
        else { return nil }
        return CloudProfile(
            accountId: accountId, firstName: firstName, lastName: lastName,
            displayName: displayName, bio: bio, birthday: contact.birthday,
            colorIndex: colorIndex, updatedAt: updatedAt
        )
    }

    private static func cloudProfile(from update: CloudUpdate, ownAccountId: String) -> CloudProfile? {
        guard
            update.type == "profile.updated",
            update.subjectAccountId == ownAccountId,
            let firstName = update.firstName,
            let lastName = update.lastName,
            let displayName = update.displayName,
            let bio = update.bio,
            let colorIndex = update.colorIndex,
            let updatedAt = update.profileUpdatedAt
        else { return nil }
        return CloudProfile(
            accountId: ownAccountId, firstName: firstName, lastName: lastName,
            displayName: displayName, bio: bio, birthday: update.birthday,
            colorIndex: colorIndex, updatedAt: updatedAt
        )
    }

    private static func cleanedProfileText(
        _ value: String,
        limit: Int,
        preservesNewlines: Bool = false
    ) -> String {
        let normalized = preservesNewlines
            ? value.replacingOccurrences(of: "\r\n", with: "\n")
            : value.replacingOccurrences(of: "\n", with: " ")
        return String(normalized.prefix(limit)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func shortDialogId(_ dialogId: String) -> String {
        String(dialogId.prefix(8))
    }

    private func delivery(from localState: String) -> Line.Delivery {
        switch localState {
        case "sending": return .sending
        case "failed": return .failed("failed")
        default: return .sent
        }
    }

    private func markReadIfNeeded(dialogId: String, messages: [LocalMessage]) async {
        guard let accountId = storedSession?.session.accountId, let localStore else { return }
        guard let maxMsgId = messages.compactMap(\.msgId).max() else { return }

        do {
            let current = try await localStore.maxReadMsgId(dialogId: dialogId, accountId: accountId)
            guard maxMsgId > current else { return }
            try await localStore.queueReadReceipt(
                dialogId: dialogId,
                accountId: accountId,
                maxReadMsgId: maxMsgId
            )
            await refreshDialogs()
            scheduleReadReceiptRetry()
        } catch {
            status = "Could not save read position"
        }
    }

    private func scheduleReadReceiptRetry() {
        guard readReceiptRetryTask == nil else {
            // A receipt can be queued after the active drain captured its database snapshot. Keep
            // the task alive for another pass so that receipt cannot be stranded until relaunch.
            readReceiptDrainRequested = true
            return
        }
        readReceiptDrainRequested = true
        readReceiptRetryTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.readReceiptDrainRequested = false
                await self.retryPendingReadReceipts()
                if !self.readReceiptDrainRequested,
                   let localStore = self.localStore,
                   let remaining = try? await localStore.pendingReadReceiptsReady(limit: 1),
                   !remaining.isEmpty {
                    self.readReceiptDrainRequested = true
                }
            } while !Task.isCancelled && self.readReceiptDrainRequested
            self.readReceiptRetryTask = nil
        }
    }

    private func retryPendingReadReceipts() async {
        guard let token = storedSession?.session.token,
              let accountId = storedSession?.session.accountId,
              let localStore else { return }
        let receipts: [PendingReadReceipt]
        do {
            receipts = try await localStore.pendingReadReceiptsReady()
        } catch {
            return
        }

        for receipt in receipts where receipt.accountId == accountId {
            if Task.isCancelled || storedSession?.session.token != token { return }
            do {
                let response = try await api.markRead(
                    dialogId: receipt.dialogId,
                    maxReadMsgId: receipt.maxReadMsgId,
                    token: token
                )
                try await localStore.markRead(
                    dialogId: response.dialogId,
                    accountId: accountId,
                    maxReadMsgId: response.maxReadMsgId,
                    exactUnreadCount: response.unreadCount
                )
                if response.maxReadMsgId >= receipt.maxReadMsgId {
                    try await localStore.completeReadReceipt(
                        dialogId: receipt.dialogId,
                        accountId: accountId,
                        acknowledgedMsgId: response.maxReadMsgId
                    )
                } else {
                    try await localStore.failReadReceipt(
                        dialogId: receipt.dialogId,
                    accountId: accountId,
                    retryAfter: 5,
                    error: "partial acknowledgement",
                    attemptedMsgId: receipt.maxReadMsgId
                )
                }
            } catch is CancellationError {
                return
            } catch {
                if case .authenticationRequired = cloudFailureDisposition(error) { return }
                let retryAfter: TimeInterval
                if case let .transient(serverRetry) = cloudFailureDisposition(error) {
                    retryAfter = serverRetry ?? retryDelay(forRetryCount: receipt.retryCount + 1)
                } else {
                    retryAfter = retryDelay(forRetryCount: receipt.retryCount + 1)
                }
                try? await localStore.failReadReceipt(
                    dialogId: receipt.dialogId,
                    accountId: accountId,
                    retryAfter: retryAfter,
                    error: error.localizedDescription,
                    attemptedMsgId: receipt.maxReadMsgId
                )
                BackgroundRuntimeCoordinator.shared.scheduleAppRefresh(
                    earliestBeginDate: Date(timeIntervalSinceNow: retryAfter)
                )
            }
        }
    }

    private func retryPendingOutbox() async {
        guard !retryInFlight else { return }
        guard let token = storedSession?.session.token, let localStore else { return }

        retryInFlight = true
        defer { retryInFlight = false }

        do {
            let items = try await localStore.pendingOutboxReady()
            for item in items {
                try Task.checkCancellation()
                try await localStore.markRetrying(clientMsgId: item.clientMsgId)
                if activeDialogId == item.dialogId {
                    await loadLocalLines(dialogId: item.dialogId)
                }
                await refreshDialogs()

                do {
                    try await sendOutboxItem(item, token: token)
                } catch {
                    let disposition = cloudOperationFailureDisposition(
                        error, serverAdvertisesFeature: capabilities.contains(.replies)
                    )
                    if case let .transient(retryAfter) = disposition {
                        let delay = retryAfter ?? retryDelay(forRetryCount: item.retryCount + 1)
                        try? await localStore.markFailed(clientMsgId: item.clientMsgId, retryAfter: delay)
                        publishTransportFailure(error)
                    } else {
                        try? await localStore.markFailed(clientMsgId: item.clientMsgId, terminal: true)
                        presentNotice("Message was not sent", message: error.localizedDescription)
                    }
                    if activeDialogId == item.dialogId {
                        await loadLocalLines(dialogId: item.dialogId)
                    }
                    await refreshDialogs()
                }
            }
        } catch {
            status = "Outbox retry failed: \(error.localizedDescription)"
        }
        await retryMediaTransfers()
    }

    private func retryMediaTransfers() async {
        guard let localStore else { return }
        do {
            for transfer in try await localStore.mediaTransfersReady() {
                try Task.checkCancellation()
                await runMediaTransfer(transfer)
            }
        } catch is CancellationError {
            return
        } catch {
            status = "Media retry failed: \(error.localizedDescription)"
        }
    }

    private func runMediaTransfer(_ transfer: MediaTransferRecord) async {
        if let existing = mediaTransferTasks[transfer.transferId] {
            await existing.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            await self.processMediaTransfer(transfer)
        }
        mediaTransferTasks[transfer.transferId] = task
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
        mediaTransferTasks.removeValue(forKey: transfer.transferId)
    }

    private func processMediaTransfer(_ initial: MediaTransferRecord) async {
        guard !mediaTransfersInFlight.contains(initial.transferId) else { return }
        guard
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let localStore
        else { return }
        mediaTransfersInFlight.insert(initial.transferId)
        defer { mediaTransfersInFlight.remove(initial.transferId) }
        do {
            try Task.checkCancellation()
            let mediaId: String
            if initial.state == "ready_to_send", let existing = initial.mediaId {
                mediaId = existing
            } else {
                mediaId = try await mediaEngine.upload(
                    transfer: initial, token: token, localStore: localStore,
                    useMultipartV2: capabilities.contains(.multipartMedia),
                    progress: { [weak self] progress in
                        await MainActor.run {
                            guard let self else { return }
                            if let index = self.lines.firstIndex(where: { $0.clientMsgId == initial.clientMsgId }) {
                                self.lines[index].transferProgress = progress
                                self.lines[index].transferStage = progress >= 0.97 ? .finalizing : .uploading
                            }
                            if self.activeDialogId == initial.dialogId {
                                self.composerMode = .uploading(
                                    Self.demoAttachment(
                                        kind: initial.kind, fileName: initial.fileName,
                                        byteSize: initial.byteSize, durationMs: initial.durationMs
                                    ), progress: progress
                                )
                            }
                        }
                    }
                )
                try await localStore.updateMediaTransfer(
                    transferId: initial.transferId, mediaId: mediaId,
                    uploadOffset: initial.byteSize, state: "ready_to_send", error: nil
                )
            }
            guard let ready = try await localStore.mediaTransfer(id: initial.transferId) else {
                throw CloudAppModelError.localStoreUnavailable
            }
            try await localStore.insertSendingMedia(ready, senderAccountId: accountId)
            if activeDialogId == ready.dialogId { await loadLocalLines(dialogId: ready.dialogId) }
            try Task.checkCancellation()
            guard
                storedSession?.session.token == token,
                storedSession?.session.accountId == accountId
            else { throw CancellationError() }
            // Once the idempotent send request begins it is the commit point. Hide the upload cancel
            // control so the UI never promises cancellation after the server may have committed.
            if activeComposerTransferId == ready.transferId {
                activeComposerTransferId = nil
                if case .uploading = composerMode { composerMode = .text }
            }
            let response = try await api.sendMediaMessage(
                dialogId: ready.dialogId, clientMsgId: ready.clientMsgId,
                body: ready.caption, mediaId: mediaId, replyToMsgId: ready.replyToMsgId,
                token: token
            )
            try await localStore.markSent(response, senderAccountId: accountId)
            let promotedToCache = await mediaEngine.finishUpload(ready, localStore: localStore)
            try await localStore.completeMediaTransfer(transferId: ready.transferId)
            if !promotedToCache {
                await mediaEngine.discardTransfer(ready)
            }
            if activeDialogId == ready.dialogId, case .uploading = composerMode { composerMode = .text }
            if activeDialogId == ready.dialogId { await loadLocalLines(dialogId: ready.dialogId) }
            await refreshDialogs()
            scheduleSync()
            status = "Sent"
        } catch is CancellationError {
            let current = (try? await localStore.mediaTransfer(id: initial.transferId)) ?? initial
            await cancelMediaTransfer(current, token: token)
            if activeDialogId == initial.dialogId, case .uploading = composerMode { composerMode = .text }
        } catch {
            let current = try? await localStore.mediaTransfer(id: initial.transferId)
            if activeDialogId == initial.dialogId, case .uploading = composerMode { composerMode = .text }
            switch cloudOperationFailureDisposition(
                error, serverAdvertisesFeature: capabilities.contains(.media)
            ) {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: initial.retryCount + 1)
                try? await localStore.updateMediaTransfer(
                    transferId: initial.transferId, mediaId: current?.mediaId,
                    uploadOffset: current?.uploadOffset ?? initial.uploadOffset,
                    state: current?.mediaId == nil ? "pending" : "uploading",
                    error: error.localizedDescription, retryAfter: delay
                )
                publishTransportFailure(error)
                status = "Attachment queued for retry"
                scheduleOutboxRetry(after: delay)
            case .unsupportedServer:
                try? await localStore.markMediaTerminal(
                    clientMsgId: initial.clientMsgId, error: "Server upgrade required"
                )
                await refreshServerCapabilities()
                presentNotice("Server upgrade required", message: "This server does not support attachments yet.")
            case .authenticationRequired:
                try? await localStore.markMediaTerminal(
                    clientMsgId: initial.clientMsgId, error: "Sign in required"
                )
                presentNotice("Sign in again", message: "Your session ended before the attachment was sent.")
            case .permanent:
                try? await localStore.markMediaTerminal(
                    clientMsgId: initial.clientMsgId, error: error.localizedDescription
                )
                presentNotice("Attachment was not sent", message: error.localizedDescription)
            }
            if activeDialogId == initial.dialogId { await loadLocalLines(dialogId: initial.dialogId) }
            await refreshDialogs()
        }
    }

    private func cancelMediaTransfer(_ transfer: MediaTransferRecord, token: String) async {
        await mediaEngine.cancelUpload(transfer, token: token)
        try? await localStore?.cancelMediaTransfer(
            transferId: transfer.transferId, clientMsgId: transfer.clientMsgId
        )
        lines.removeAll { $0.clientMsgId == transfer.clientMsgId }
        if activeDialogId == transfer.dialogId { await loadLocalLines(dialogId: transfer.dialogId) }
        await refreshDialogs()
    }

    private static func demoAttachment(
        kind: String, fileName: String?, byteSize: Int64, durationMs: Int64?
    ) -> DemoAttachment {
        let duration = durationMs.map {
            let seconds = max(0, $0 / 1_000)
            return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
        } ?? ""
        switch kind {
        case "photo": return .photo(name: fileName ?? String(localized: "Photo"))
        case "video": return .video(name: fileName ?? String(localized: "Video"), duration: duration)
        case "voice": return .voice(duration: duration.isEmpty ? "0:00" : duration)
        default: return .file(
            name: fileName ?? String(localized: "File"),
            size: ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
        )
        }
    }

    private func sendOutboxItem(_ item: PendingOutboxItem, token: String) async throws {
        let response: SendMessageResponse
        if let sourceDialogId = item.forwardedFromDialogId, let sourceMsgId = item.forwardedFromMsgId {
            response = try await api.forwardMessage(
                dialogId: item.dialogId,
                clientMsgId: item.clientMsgId,
                sourceDialogId: sourceDialogId,
                sourceMsgId: sourceMsgId,
                token: token
            )
        } else {
            response = try await api.sendMessage(
                dialogId: item.dialogId,
                clientMsgId: item.clientMsgId,
                body: item.body,
                replyToMsgId: item.replyToMsgId,
                token: token
            )
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            try await localStore.markSent(response, senderAccountId: accountId)
            if activeDialogId == response.dialogId {
                await loadLocalLines(dialogId: response.dialogId)
            }
            await refreshDialogs()
        } else if let index = lines.firstIndex(where: { $0.clientMsgId == item.clientMsgId }) {
            lines[index].dialogId = response.dialogId
            lines[index].msgId = response.msgId
            lines[index].delivery = .sent
        }

        status = response.duplicate ? "Send confirmed" : "Sent"
        scheduleSync()
    }

    private func nextOutboxRetryDelay() async -> TimeInterval? {
        guard let localStore else { return nil }
        let textDelay = try? await localStore.nextPendingOutboxDelay()
        let mediaDelay = try? await localStore.nextMediaTransferDelay()
        let mutationDelay = try? await localStore.nextMessageMutationDelay()
        return [textDelay, mediaDelay, mutationDelay].compactMap { $0 }.min()
    }

    private func retryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, retryCount - 1))))
    }

    private func upsert(_ message: CloudMessage) {
        if message.state == "deleted_for_all" {
            lines.removeAll {
                $0.clientMsgId == message.clientMsgId
                    || ($0.dialogId == message.dialogId && $0.msgId == message.msgId)
            }
            return
        }
        let mine = message.senderAccountId == storedSession?.session.accountId
        if let index = lines.firstIndex(where: { $0.clientMsgId == message.clientMsgId }) {
            lines[index].dialogId = message.dialogId
            lines[index].msgId = message.msgId
            lines[index].senderAccountId = message.senderAccountId
            lines[index].text = message.text
            lines[index].replyToMsgId = message.replyToMsgId
            lines[index].reactions = Self.reactionBadges(message.reactions)
            lines[index].myReaction = message.reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji
            lines[index].forwardedFromAccountId = message.forwardedFromAccountId
            lines[index].forwardedFromDialogId = message.forwardedFromDialogId
            lines[index].forwardedFromMsgId = message.forwardedFromMsgId
            lines[index].isForwarded = message.isForwarded
            lines[index].editVersion = message.editVersion
            lines[index].isEdited = message.editVersion > 0 && message.state == "visible"
            lines[index].isDeleted = message.state == "deleted_for_all"
            lines[index].media = message.media
            lines[index].mine = mine
            lines[index].delivery = .sent
            lines[index].timestamp = message.serverTs
            return
        }
        lines.append(Line(
            id: message.id,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            senderAccountId: message.senderAccountId,
            text: message.text,
            mine: mine,
            delivery: .sent,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            reactions: Self.reactionBadges(message.reactions),
            myReaction: message.reactions.first(where: { $0.accountId == storedSession?.session.accountId })?.emoji,
            forwardedFromAccountId: message.forwardedFromAccountId,
            forwardedFromDialogId: message.forwardedFromDialogId,
            forwardedFromMsgId: message.forwardedFromMsgId,
            isForwarded: message.isForwarded,
            editVersion: message.editVersion,
            isEdited: message.editVersion > 0 && message.state == "visible",
            isDeleted: message.state == "deleted_for_all",
            media: message.media
        ))
        lines.sort {
            switch ($0.msgId, $1.msgId) {
            case let (lhs?, rhs?): return lhs < rhs
            case (.some, nil): return true
            case (nil, .some): return false
            case (nil, nil): return $0.id < $1.id
            }
        }
    }

    private func edit(_ line: Line, text: String) async {
        guard
            let localStore,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId,
                operation: "edit",
                dialogId: dialogId,
                msgId: msgId,
                body: text,
                expectedEditVersion: line.editVersion
            )
            draft = ""
            composerMode = .text
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "edit", dialogId: dialogId,
                msgId: msgId, body: text, expectedEditVersion: line.editVersion,
                emoji: nil, retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Edit failed: \(error.localizedDescription)"
            presentNotice("Could not edit message", message: error.localizedDescription)
        }
    }

    func deleteMessage(_ line: Line) async {
        #if DEBUG
        if isDemoMode {
            deleteDemoMessage(line.id)
            return
        }
        #endif
        guard
            let localStore,
            line.mine,
            !line.isDeleted,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId, operation: "delete",
                dialogId: dialogId, msgId: msgId
            )
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "delete", dialogId: dialogId,
                msgId: msgId, body: nil, expectedEditVersion: nil, emoji: nil,
                retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
            presentNotice("Could not delete message", message: error.localizedDescription)
        }
    }

    func reactToMessage(_ line: Line, reaction: String = "❤️") async {
        #if DEBUG
        if isDemoMode {
            reactToDemoMessage(line.id, reaction: reaction)
            return
        }
        #endif
        guard
            let localStore,
            !line.isDeleted,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        let targetKey = "\(dialogId):\(msgId)"
        guard mutationTargetsBeingQueued.insert(targetKey).inserted else { return }
        defer { mutationTargetsBeingQueued.remove(targetKey) }
        let desiredReaction: String? = line.myReaction == reaction ? nil : reaction
        do {
            let mutationId = UUID().uuidString.lowercased()
            try await localStore.enqueueMessageMutation(
                clientMutationId: mutationId, operation: "reaction",
                dialogId: dialogId, msgId: msgId, emoji: desiredReaction
            )
            await loadLocalLines(dialogId: dialogId)
            await processMessageMutation(PendingMessageMutation(
                clientMutationId: mutationId, operation: "reaction", dialogId: dialogId,
                msgId: msgId, body: nil, expectedEditVersion: nil, emoji: desiredReaction,
                retryCount: 0, nextRetryAt: nil, lastError: nil
            ))
        } catch {
            status = "Reaction failed: \(error.localizedDescription)"
            presentNotice("Could not update reaction", message: error.localizedDescription)
        }
    }

    func forwardMessage(_ line: Line, to targetDialogId: String) async {
        #if DEBUG
        if isDemoMode {
            status = "Forwarded"
            return
        }
        #endif
        guard
            !line.isDeleted,
            let token = storedSession?.session.token,
            let accountId = storedSession?.session.accountId,
            let sourceDialogId = line.dialogId,
            let sourceMsgId = line.msgId
        else { return }
        let clientMsgId = UUID().uuidString.lowercased()
        do {
            if let localStore {
                _ = try await localStore.insertSending(
                    dialogId: targetDialogId,
                    clientMsgId: clientMsgId,
                    text: line.text,
                    senderAccountId: accountId,
                    forwardedFromAccountId: line.senderAccountId,
                    forwardedFromDialogId: sourceDialogId,
                    forwardedFromMsgId: sourceMsgId
                )
            }
            await refreshDialogs()
            try await sendOutboxItem(
                PendingOutboxItem(
                    clientMsgId: clientMsgId,
                    dialogId: targetDialogId,
                    body: line.text,
                    replyToMsgId: nil,
                    forwardedFromDialogId: sourceDialogId,
                    forwardedFromMsgId: sourceMsgId,
                    retryCount: 0,
                    nextRetryAt: nil
                ),
                token: token
            )
            status = "Forwarded"
        } catch {
            if let localStore {
                try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: retryDelay(forRetryCount: 1))
                await refreshDialogs()
                scheduleOutboxRetry(after: retryDelay(forRetryCount: 1))
            }
            status = "Forward failed: \(error.localizedDescription)"
        }
    }

    private static func reactionBadges(_ reactions: [CloudReaction]) -> [String] {
        let grouped = Dictionary(grouping: reactions, by: \.emoji)
        return grouped.keys.sorted().map { emoji in
            let count = grouped[emoji]?.count ?? 0
            return count > 1 ? "\(emoji) \(count)" : emoji
        }
    }

    private func retryPendingMessageMutations() async {
        guard let localStore else { return }
        do {
            for mutation in try await localStore.pendingMessageMutationsReady() {
                try Task.checkCancellation()
                await processMessageMutation(mutation)
            }
        } catch is CancellationError {
            return
        } catch {
            presentNotice("Could not resume message changes", message: error.localizedDescription)
        }
    }

    private func processMessageMutation(_ mutation: PendingMessageMutation) async {
        guard !messageMutationsInFlight.contains(mutation.clientMutationId) else { return }
        guard let token = storedSession?.session.token, let localStore else { return }
        messageMutationsInFlight.insert(mutation.clientMutationId)
        defer { messageMutationsInFlight.remove(mutation.clientMutationId) }

        do {
            let response: MessageMutationResponse
            switch mutation.operation {
            case "edit":
                guard let body = mutation.body, let expected = mutation.expectedEditVersion else {
                    throw CloudAppModelError.localStoreUnavailable
                }
                response = try await api.editMessage(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    expectedEditVersion: expected,
                    body: body,
                    token: token
                )
            case "delete":
                response = try await api.deleteMessage(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    token: token
                )
            case "reaction":
                response = try await api.setReaction(
                    dialogId: mutation.dialogId,
                    msgId: mutation.msgId,
                    clientMutationId: mutation.clientMutationId,
                    emoji: mutation.emoji,
                    token: token
                )
            default:
                throw CloudAppModelError.localStoreUnavailable
            }

            try await localStore.applyMessageMutation(response)
            try await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
            if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
            await refreshDialogs()
            setReplicaSyncState(.ready)
            status = response.duplicate ? "Change confirmed" : "Updated"
            scheduleSync()
        } catch {
            if let apiError = error as? CloudAPIError, apiError.status == 409 {
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                await syncNow()
                if mutation.operation == "edit", let body = mutation.body {
                    draft = body
                    if let current = lines.first(where: { $0.msgId == mutation.msgId }) {
                        composerMode = .editing(messageId: current.id, original: current.text)
                    }
                }
                presentNotice(
                    "Message changed on another device",
                    message: mutation.operation == "edit"
                        ? "The latest message was loaded and your edit was restored. Review it and send again."
                        : "The latest message state has been loaded."
                )
                return
            }

            let featureIsAdvertised: Bool = switch mutation.operation {
            case "reaction": capabilities.contains(.reactions)
            default: capabilities.contains(.editing) || capabilities.contains(.deletion)
            }
            switch cloudOperationFailureDisposition(
                error, serverAdvertisesFeature: featureIsAdvertised
            ) {
            case let .transient(retryAfter):
                let delay = retryAfter ?? retryDelay(forRetryCount: mutation.retryCount + 1)
                try? await localStore.markMessageMutationFailed(
                    clientMutationId: mutation.clientMutationId,
                    error: error.localizedDescription,
                    retryAfter: delay,
                    terminal: false
                )
                publishTransportFailure(error)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                scheduleOutboxRetry(after: delay)
            case .unsupportedServer:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                await refreshServerCapabilities()
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Server upgrade required", message: "This server does not support that message action yet.")
            case .authenticationRequired:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Sign in again", message: "Your session ended before the message could be changed.")
            case .permanent:
                try? await localStore.completeMessageMutation(clientMutationId: mutation.clientMutationId)
                if activeDialogId == mutation.dialogId { await loadLocalLines(dialogId: mutation.dialogId) }
                presentNotice("Message was not changed", message: error.localizedDescription)
            }
        }
    }

    #if DEBUG
    func enterDemoMode() {
        isDemoMode = true
        storedSession = StoredCloudSession(
            session: CloudSession(accountId: "debug-demo-account", deviceId: "debug-demo-device", token: "debug-demo-token"),
            phone: "+992 00 000 00 00",
            displayName: "Меҳмон"
        )
        status = "Demo mode"
        launchPhase = .localReady
        profileDetails = Self.profileDetails(from: "Меҳмон")
        setReplicaSyncState(.ready)
        activeDialogId = nil
        draft = ""
        peerPhone = ""
        lines = []
        canLoadEarlier = false

        dialogs = [
            Dialog(id: "demo-mehrona", title: "Меҳрона", subtitle: "Шоми Душанбе", updatedAt: Self.demoTimestamp(minutesAgo: 2), isPending: false, unreadCount: 2, isPinned: true, mentionCount: 1, previewKind: .photo),
            Dialog(id: "demo-firooz", title: "Фирӯз", subtitle: "Документы получил, спасибо", updatedAt: Self.demoTimestamp(minutesAgo: 23), isPending: false, unreadCount: 4, isMuted: true, previewKind: .file),
            Dialog(id: "demo-madina", title: "Мадина", subtitle: "Дар роҳам", updatedAt: Self.demoTimestamp(minutesAgo: 1_480), isPending: false, unreadCount: 0, draftPreview: "Пас аз даҳ дақиқа…"),
            Dialog(id: "demo-aziz", title: "Азиз", subtitle: "Созвонимся вечером?", updatedAt: Self.demoTimestamp(minutesAgo: 2_920), isPending: false, unreadCount: 0, isTyping: true, lastMessageMine: true),
        ]
        draftsByDialog = ["demo-madina": "Пас аз даҳ дақиқа…"]

        demoLinesByDialog = [
            "demo-mehrona": [
                demoLine(dialogId: "demo-mehrona", messageId: 1, text: "Салом! Пагоҳ вақт дорӣ?", mine: false, minutesAgo: 1_565),
                demoLine(dialogId: "demo-mehrona", messageId: 2, text: "Салом 👋 Бале, баъди соати ҳафт.", mine: true, minutesAgo: 1_562, delivery: .seen),
                demoLine(dialogId: "demo-mehrona", messageId: 3, text: "Агар хоҳӣ, дар маркази шаҳр вомехӯрем.", mine: true, minutesAgo: 1_561, delivery: .seen),
                Line(id: "demo-mehrona-4", dialogId: "demo-mehrona", msgId: 4, clientMsgId: "demo-mehrona-4", text: "Зӯр! То пагоҳ 🎉", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 1_558), reactions: ["🔥"], myReaction: "🔥"),
                demoLine(dialogId: "demo-mehrona", messageId: 5, text: "Имрӯз соати чанд вомехӯрем?", mine: false, minutesAgo: 9),
                Line(id: "demo-mehrona-6", dialogId: "demo-mehrona", msgId: 6, clientMsgId: "demo-mehrona-6", text: "Соати ҳафт мешавад?", mine: true, delivery: .seen, timestamp: Self.demoTimestamp(minutesAgo: 7), replyToMsgId: 5, replyPreview: "Имрӯз соати чанд вомехӯрем?", reactions: ["❤️"]),
                demoLine(dialogId: "demo-mehrona", messageId: 7, text: "Олично. Тогда до вечера.", mine: false, minutesAgo: 4),
                Line(id: "demo-mehrona-8", dialogId: "demo-mehrona", msgId: 8, clientMsgId: "demo-mehrona-8", text: "Шоми Душанбе", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 1), attachment: .photo(name: "Шоми Душанбе")),
            ],
            "demo-firooz": [
                demoLine(dialogId: "demo-firooz", messageId: 1, text: "Салом, файлҳоро фиристодам.", mine: true, minutesAgo: 31, delivery: .seen),
                demoLine(dialogId: "demo-firooz", messageId: 2, text: "Документы получил, спасибо", mine: false, minutesAgo: 23),
                Line(id: "demo-firooz-3", dialogId: "demo-firooz", msgId: 3, clientMsgId: "demo-firooz-3", text: "Toj product brief", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 22), attachment: .file(name: "Toj-Brief.pdf", size: "2.4 MB")),
            ],
            "demo-madina": [
                demoLine(dialogId: "demo-madina", messageId: 1, text: "Кай мерасӣ?", mine: true, minutesAgo: 1_490, delivery: .seen),
                demoLine(dialogId: "demo-madina", messageId: 2, text: "Дар роҳам", mine: false, minutesAgo: 1_480),
            ],
            "demo-aziz": [
                demoLine(dialogId: "demo-aziz", messageId: 1, text: "Созвонимся вечером?", mine: false, minutesAgo: 2_920),
            ],
        ]
        demoLinesByDialog = demoLinesByDialog.mapValues(Self.applyingPresentation)
    }

    private func leaveDemoMode() {
        isDemoMode = false
        storedSession = nil
        activeDialogId = nil
        dialogs = []
        lines = []
        devices = []
        demoLinesByDialog = [:]
        requestedCode = false
        accountDeletionRequested = false
        accountDeletionCode = ""
        status = "Signed out"
        launchPhase = .signedOut
    }

    private func sendDemo(_ text: String, replyPreview: String? = nil, attachment: DemoAttachment? = nil) {
        guard let dialogId = activeDialogId else { return }
        openingTimelineAnchor = .bottom
        timelineTopVisibleMsgId = nil
        timelineIsAtBottom = true
        let lineId = UUID().uuidString
        let nextMessageId = (demoLinesByDialog[dialogId]?.compactMap(\.msgId).max() ?? 0) + 1
        let line = Line(
            id: lineId,
            dialogId: dialogId,
            msgId: nextMessageId,
            clientMsgId: lineId,
            text: text,
            mine: true,
            delivery: .sent,
            timestamp: Self.demoTimestamp(minutesAgo: 0),
            replyPreview: replyPreview,
            attachment: attachment
        )
        demoLinesByDialog[dialogId, default: []].append(line)
        demoLinesByDialog[dialogId] = Self.applyingPresentation(demoLinesByDialog[dialogId] ?? [])
        lines = demoLinesByDialog[dialogId] ?? []
        dialogs = dialogs.map { dialog in
            guard dialog.id == dialogId else { return dialog }
            var updated = dialog
            updated.subtitle = text
            updated.updatedAt = Self.demoTimestamp(minutesAgo: 0)
            updated.isPending = false
            updated.unreadCount = 0
            updated.draftPreview = nil
            updated.previewKind = attachment?.chatListPreviewKind ?? .text
            updated.lastMessageMine = true
            return updated
        }

        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard let self, self.isDemoMode, self.activeDialogId == dialogId else { return }
            if let index = self.lines.firstIndex(where: { $0.id == lineId }) {
                self.lines[index].delivery = .seen
                self.demoLinesByDialog[dialogId] = self.lines
            }
        }
    }

    func reactToDemoMessage(_ lineId: String, reaction: String = "❤️") {
        guard isDemoMode, let dialogId = activeDialogId,
              let index = lines.firstIndex(where: { $0.id == lineId }) else { return }
        if lines[index].reactions.contains(reaction) {
            lines[index].reactions.removeAll(where: { $0 == reaction })
        } else {
            lines[index].reactions.append(reaction)
        }
        demoLinesByDialog[dialogId] = lines
    }

    func deleteDemoMessage(_ lineId: String) {
        guard isDemoMode, let dialogId = activeDialogId else { return }
        lines.removeAll(where: { $0.id == lineId })
        lines = Self.applyingPresentation(lines)
        demoLinesByDialog[dialogId] = lines
    }

    func sendDemoAttachment(_ attachment: DemoAttachment, caption: String = "") {
        guard isDemoMode else { return }
        sendDemo(caption.isEmpty ? attachment.title : caption, attachment: attachment)
        composerMode = .text
    }

    func beginDemoRecording() {
        guard isDemoMode, capabilities.contains(.voiceNotes) else { return }
        composerMode = .recording(elapsedSeconds: 0)
    }

    func finishDemoRecording() {
        guard isDemoMode else { return }
        sendDemo(String(localized: "Voice message"), attachment: .voice(duration: "0:08"))
        composerMode = .text
    }

    private func updateDemoMessage(messageId: String, text: String) {
        guard let dialogId = activeDialogId,
              let index = lines.firstIndex(where: { $0.id == messageId }) else { return }
        lines[index].text = text
        lines[index].isEdited = true
        lines = Self.applyingPresentation(lines)
        demoLinesByDialog[dialogId] = lines
    }

    private func demoLine(
        dialogId: String,
        messageId: Int64,
        text: String,
        mine: Bool,
        minutesAgo: Int,
        delivery: Line.Delivery = .sent
    ) -> Line {
        Line(
            id: "\(dialogId)-\(messageId)",
            dialogId: dialogId,
            msgId: messageId,
            clientMsgId: "\(dialogId)-\(messageId)",
            text: text,
            mine: mine,
            delivery: delivery,
            timestamp: Self.demoTimestamp(minutesAgo: minutesAgo)
        )
    }

    private static func demoTimestamp(minutesAgo: Int) -> String {
        ISO8601DateFormatter().string(from: Date().addingTimeInterval(TimeInterval(-minutesAgo * 60)))
    }

    private static func applyingPresentation(_ source: [Line]) -> [Line] {
        var result = source
        let inputs = source.map {
            TimelinePresentationInput(id: $0.id, mine: $0.mine, timestamp: $0.timestamp)
        }
        let metadata = Dictionary(uniqueKeysWithValues: TimelinePresentationBuilder.build(inputs).map {
            ($0.id, $0)
        })
        for index in result.indices {
            guard let value = metadata[result[index].id] else { continue }
            result[index].presentationDayLabel = value.dayLabel
            result[index].presentationTimestampLabel = value.timestampLabel
            result[index].presentationMediaTimestampLabel = value.mediaTimestampLabel
            result[index].presentationIsFirstInGroup = value.isFirstInGroup
            result[index].presentationIsLastInGroup = value.isLastInGroup
        }
        return result
    }

    private func demoMediaBytes(for media: CloudMedia, thumbnail: Bool) -> Data? {
        guard media.kind == "photo" || thumbnail else { return nil }

        let side: CGFloat = thumbnail ? 320 : 1_200
        let size = CGSize(width: side, height: side * 0.72)
        let renderer = UIGraphicsImageRenderer(size: size)
        let image = renderer.image { context in
            let bounds = CGRect(origin: .zero, size: size)
            UIColor(red: 0.05, green: 0.06, blue: 0.08, alpha: 1).setFill()
            context.fill(bounds)

            let accent = UIColor(red: 0.84, green: 0.66, blue: 0.21, alpha: 1)
            accent.withAlphaComponent(0.18).setFill()
            context.cgContext.fillEllipse(in: bounds.insetBy(dx: side * 0.16, dy: side * 0.05))

            let symbolName = media.kind == "video" ? "play.fill" : "photo.fill"
            let configuration = UIImage.SymbolConfiguration(pointSize: side * 0.14, weight: .medium)
            let symbol = UIImage(systemName: symbolName, withConfiguration: configuration)?
                .withTintColor(accent, renderingMode: .alwaysOriginal)
            symbol?.draw(at: CGPoint(x: bounds.midX - side * 0.07, y: bounds.midY - side * 0.07))
        }
        return image.jpegData(compressionQuality: thumbnail ? 0.72 : 0.88)
    }
    #endif

    #if !DEBUG
    func reactToDemoMessage(_ lineId: String, reaction: String = "❤️") {}
    func deleteDemoMessage(_ lineId: String) {}
    func sendDemoAttachment(_ attachment: DemoAttachment, caption: String = "") {}
    func beginDemoRecording() {}
    func finishDemoRecording() {}
    #endif
}

private actor CloudLocalStoreBootstrapper {
    private var store: CloudLocalStore?

    func openDefaultStore() throws -> CloudLocalStore {
        if let store { return store }
        let opened = try CloudLocalStore.default()
        store = opened
        return opened
    }

    func quarantineAndOpenDefaultStore() throws -> CloudLocalStore {
        _ = try CloudLocalStore.quarantineDefaultStore()
        let opened = try CloudLocalStore.default()
        store = opened
        return opened
    }

    func destroyDefaultStore() throws {
        store = nil
        try CloudLocalStore.destroyDefaultStore()
    }

    /// Verifies explicit logout at the filesystem boundary even if cache cleanup encountered a
    /// partially initialized index. Only Toj-owned cache, profile-photo, resume, and preview paths
    /// are touched; this runs before the shared SQLCipher/profile-photo key is destroyed.
    func destroyDefaultMediaState() throws {
        let fileManager = FileManager.default
        let support = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let tojSupport = support.appending(path: "Toj", directoryHint: .isDirectory)
        let urls = [
            tojSupport.appending(path: "media", directoryHint: .isDirectory),
            tojSupport.appending(path: "background-media-jobs.json"),
            fileManager.temporaryDirectory.appending(
                path: "TojMediaPreviews",
                directoryHint: .isDirectory
            ),
        ]
        var firstError: Error?
        do {
            try EncryptedProfilePhotoStore.destroyAllSynchronously()
        } catch {
            firstError = error
        }
        for url in urls where fileManager.fileExists(atPath: url.path) {
            do {
                try fileManager.removeItem(at: url)
            } catch {
                if firstError == nil { firstError = error }
            }
        }
        if let firstError { throw firstError }
    }
}

private enum CloudAppModelError: LocalizedError {
    case bootstrapRequired
    case localStoreUnavailable
    case invalidBootstrapCursor

    var errorDescription: String? {
        switch self {
        case .bootstrapRequired:
            return "Bootstrap required"
        case .localStoreUnavailable:
            return "Encrypted local database is unavailable"
        case .invalidBootstrapCursor:
            return "Server returned an incomplete bootstrap page"
        }
    }
}
