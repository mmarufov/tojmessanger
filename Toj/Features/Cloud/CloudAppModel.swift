import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CloudAppModel {
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
    }

    struct Line: Identifiable, Equatable {
        enum Delivery: Equatable {
            case sending
            case sent
            case seen
            case failed(String)
        }

        let id: String
        var dialogId: String?
        var msgId: Int64?
        var clientMsgId: String
        var text: String
        var mine: Bool
        var delivery: Delivery
        var timestamp: String?
        var replyToMsgId: Int64? = nil
        var replyPreview: String? = nil
        var reactions: [String] = []
        var editVersion = 0
        var isEdited = false
        var isDeleted = false
        var attachment: DemoAttachment? = nil
    }

    private(set) var storedSession: StoredCloudSession?
    private(set) var status = "Starting"
    private(set) var requestedCode = false
    private(set) var authRequestInFlight = false
    private(set) var authVerifyInFlight = false
    private(set) var resendSeconds = 0
    private(set) var activeDialogId: String?
    private(set) var dialogs: [Dialog] = []
    private(set) var lines: [Line] = []
    private(set) var canLoadEarlier = false
    private(set) var loadingEarlier = false
    private(set) var devices: [CloudDevice] = []
    private(set) var loadingDevices = false
    private(set) var accountDeletionRequested = false
    private(set) var accountDeletionInFlight = false
    private(set) var composerMode: ComposerMode = .text
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
    private let localStore: CloudLocalStore?
    private let pushCenter: PushRegistrationCenter
    private var pts: Int64 = 0
    private var hintSocket: CloudHintSocket?
    private var hintTask: Task<Void, Never>?
    private var syncTask: Task<Void, Never>?
    private var retryTask: Task<Void, Never>?
    private var resendTask: Task<Void, Never>?
    private var syncInFlight = false
    private var syncAgain = false
    private var retryInFlight = false
    private var uploadedPushRegistration: String?
    private var historyHasMoreByDialog: [String: Bool] = [:]
    private var draftsByDialog: [String: String] = [:]
    #if DEBUG
    private var demoLinesByDialog: [String: [Line]] = [:]
    #endif

    var capabilities: MessagingCapabilities {
        #if DEBUG
        if isDemoMode { return .demo }
        #endif
        return .productionText
    }

    var connectionViewState: ConnectionViewState {
        let normalized = status.lowercased()
        if normalized.contains("failed") || normalized.contains("network") || normalized.contains("offline") {
            return .offline
        }
        if normalized.contains("starting") || normalized.contains("looking") || normalized.contains("rebuild") {
            return .connecting
        }
        return .connected
    }

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
        useDefaultLocalStore: Bool = true
    ) {
        self.api = CloudAPI(config: config)
        self.tokenStore = tokenStore
        self.pushCenter = pushCenter
        self.localStore = injectedLocalStore ?? (useDefaultLocalStore ? try? CloudLocalStore.default() : nil)
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
        do {
            let pendingRevocation = try await tokenStore.loadPendingRevocationToken()
            let savedSession = try await tokenStore.load()
            if let pendingRevocation {
                Task { [weak self] in await self?.revokeSignedOutToken(pendingRevocation) }
            }
            if savedSession?.session.token == pendingRevocation {
                // Sign-out was interrupted after its intent was persisted but before the active
                // Keychain item was removed. Finish locally instead of restoring a revoked session.
                try await tokenStore.clear()
                status = "Signed out"
                return
            }
            if let saved = savedSession {
                storedSession = saved
                phone = saved.phone
                displayName = saved.displayName
                status = "Signed in"
                await afterSignIn()
            } else {
                status = "Signed out"
            }
        } catch {
            status = "Session restore failed: \(error.localizedDescription)"
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
            resendTask?.cancel()
            resendTask = nil
            resendSeconds = 0
            status = "Signed in"
            await afterSignIn()
        } catch {
            status = "Sign in failed: \(error.localizedDescription)"
        }
    }

    func resetAuthCode() {
        guard !authRequestInFlight, !authVerifyInFlight else { return }
        requestedCode = false
        code = ""
        status = "Signed out"
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
        hintTask?.cancel()
        syncTask?.cancel()
        retryTask?.cancel()
        resendTask?.cancel()
        resendTask = nil
        await hintSocket?.stop()
        hintSocket = nil
        var cleanupFailure: String?
        do {
            if let accountId = storedSession?.session.accountId {
                try await localStore?.clearAccount(accountId: accountId)
            }
            try await tokenStore.clear()
        } catch {
            cleanupFailure = error.localizedDescription
        }
        storedSession = nil
        activeDialogId = nil
        dialogs = []
        lines = []
        canLoadEarlier = false
        loadingEarlier = false
        historyHasMoreByDialog = [:]
        devices = []
        loadingDevices = false
        uploadedPushRegistration = nil
        pts = 0
        requestedCode = false
        authRequestInFlight = false
        authVerifyInFlight = false
        resendSeconds = 0
        code = ""
        accountDeletionRequested = false
        accountDeletionCode = ""
        status = cleanupFailure.map { "Local cleanup failed: \($0)" } ?? finalStatus
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

    func selectDialog(_ dialogId: String) async {
        if let activeDialogId {
            draftsByDialog[activeDialogId] = draft
        }
        activeDialogId = dialogId
        draft = draftsByDialog[dialogId] ?? ""
        composerMode = .text
        #if DEBUG
        if isDemoMode {
            lines = demoLinesByDialog[dialogId] ?? []
            canLoadEarlier = false
            dialogs = dialogs.map { dialog in
                guard dialog.id == dialogId, dialog.unreadCount > 0 else { return dialog }
                var updated = dialog
                updated.unreadCount = 0
                updated.mentionCount = 0
                return updated
            }
            return
        }
        #endif
        await loadLocalLines(dialogId: dialogId)
    }

    func deselectDialog(_ dialogId: String) {
        guard activeDialogId == dialogId else { return }
        draftsByDialog[dialogId] = draft
        activeDialogId = nil
        draft = ""
        composerMode = .text
        lines = []
        canLoadEarlier = false
        loadingEarlier = false
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
        guard let token = storedSession?.session.token, let dialogId = activeDialogId, let localStore else { return }

        loadingEarlier = true
        defer { loadingEarlier = false }

        do {
            guard let beforeMsgId = try await localStore.oldestServerMsgId(dialogId: dialogId) else {
                canLoadEarlier = false
                historyHasMoreByDialog[dialogId] = false
                return
            }

            let page = try await api.getHistory(dialogId: dialogId, beforeMsgId: beforeMsgId, token: token)
            try await localStore.applyHistoryPage(page)
            historyHasMoreByDialog[dialogId] = page.hasMore
            await loadLocalLines(dialogId: dialogId)
            status = page.messages.isEmpty ? "No earlier messages" : "History loaded"
        } catch {
            status = "History failed: \(error.localizedDescription)"
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
        if case let .editing(_, original) = composerMode, draft == original {
            draft = ""
        }
        composerMode = .text
    }

    func actions(for line: Line) -> [MessageAction] {
        if line.isDeleted { return [.inspect] }
        var actions: [MessageAction] = [.copy]
        if capabilities.contains(.replies) { actions.insert(.reply, at: 0) }
        if capabilities.contains(.reactions) { actions.insert(.react, at: min(1, actions.count)) }
        if line.mine, capabilities.contains(.editing) { actions.append(.edit) }
        if capabilities.contains(.forwarding) { actions.append(.forward) }
        if capabilities.contains(.deletion) { actions.append(.delete) }
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
                if let dialogId = line.dialogId, self.activeDialogId == dialogId {
                    await self.loadLocalLines(dialogId: dialogId)
                }
            }
            self.scheduleOutboxRetry()
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
                    retryCount: 0,
                    nextRetryAt: nil
                ),
                token: token
            )
        } catch {
            if let localStore {
                try? await localStore.markFailed(clientMsgId: clientMsgId, retryAfter: retryDelay(forRetryCount: 1))
                await loadLocalLines(dialogId: dialogId)
                await refreshDialogs()
                scheduleOutboxRetry(after: retryDelay(forRetryCount: 1))
            } else {
                if let index = lines.firstIndex(where: { $0.clientMsgId == clientMsgId }) {
                    lines[index].delivery = .failed(error.localizedDescription)
                }
            }
            status = "Send failed: \(error.localizedDescription)"
        }
    }

    private func afterSignIn() async {
        guard storedSession?.session.token != nil, let accountId = storedSession?.session.accountId else { return }
        do {
            pts = try await localStore?.loadPts(accountId: accountId) ?? 0
            await refreshDialogs()
            activeDialogId = nil
            lines = []
            canLoadEarlier = false
        } catch {
            pts = 0
        }
        await pushCenter.requestAuthorization()
        await resume()
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
        await syncNow()
        return pts > previousPts
    }

    func resume() async {
        #if DEBUG
        if isDemoMode { return }
        #endif
        guard let token = storedSession?.session.token else { return }
        pushCenter.refreshRegistration()
        await startHints(token: token)
        scheduleSync()
        scheduleOutboxRetry()
    }

    private func startHints(token: String) async {
        hintTask?.cancel()
        await hintSocket?.stop()

        let socket = CloudHintSocket(url: api.config.wsURL(), token: token)
        hintSocket = socket
        hintTask = Task { [weak self, socket] in
            await socket.start()
            for await _ in socket.hints {
                await self?.syncNow()
            }
        }
    }

    private func scheduleSync() {
        guard syncTask == nil else {
            syncAgain = true
            return
        }
        syncTask = Task { [weak self] in
            await self?.syncNow()
            await MainActor.run { self?.syncTask = nil }
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

    private func syncNow() async {
        guard let token = storedSession?.session.token else { return }
        if syncInFlight {
            syncAgain = true
            return
        }

        syncInFlight = true
        defer { syncInFlight = false }

        repeat {
            syncAgain = false
            do {
                var response = try await api.getDifference(sincePts: pts, token: token)
                while true {
                    if response.kind == "difference_too_long" {
                        try await rebuildLocalReplica(token: token)
                        response = try await api.getDifference(sincePts: pts, token: token)
                        continue
                    }
                    try await apply(response)
                    pts = response.state.pts
                    if response.kind != "difference_slice" { break }
                    response = try await api.getDifference(sincePts: pts, token: token)
                }
                status = "Synced"
                scheduleOutboxRetry()
            } catch {
                status = "Sync failed: \(error.localizedDescription)"
                return
            }
        } while syncAgain
    }

    private func apply(_ difference: DifferenceResponse) async throws {
        if difference.kind == "difference_too_long" {
            throw CloudAppModelError.bootstrapRequired
        }

        if let localStore, let accountId = storedSession?.session.accountId {
            try await localStore.applyDifference(difference, accountId: accountId)
            await refreshDialogs()
            if let dialogId = activeDialogId {
                await loadLocalLines(dialogId: dialogId)
            }
        } else {
            for update in difference.updates ?? [] {
                guard ["message.new", "message.edited", "message.deleted"].contains(update.type),
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
        let bootstrap = try await api.startBootstrap(token: token)
        try await localStore.beginBootstrap(accountId: accountId)

        var cursor: String?
        while true {
            let page = try await api.getBootstrapDialogs(
                bootstrapToken: bootstrap.token,
                cursor: cursor,
                token: token
            )
            try await localStore.applyBootstrapPage(page)

            if !page.hasMore { break }
            guard let nextCursor = page.nextCursor else {
                throw CloudAppModelError.invalidBootstrapCursor
            }
            cursor = nextCursor
        }

        try await localStore.finishBootstrap(accountId: accountId, pts: bootstrap.state.pts)
        pts = bootstrap.state.pts
        await refreshDialogs()
        activeDialogId = nil
        lines = []
        canLoadEarlier = false
    }

    private func refreshDialogs() async {
        guard let localStore, let accountId = storedSession?.session.accountId else { return }
        do {
            dialogs = try await localStore.dialogs(accountId: accountId).map(dialog(from:))
        } catch {
            status = "Dialog load failed: \(error.localizedDescription)"
        }
    }

    private func loadLocalLines(dialogId: String) async {
        guard let localStore else { return }
        do {
            let messages = try await localStore.messages(dialogId: dialogId)
            let accountId = storedSession?.session.accountId
            let peerReadMsgId: Int64
            if let accountId {
                peerReadMsgId = try await localStore.maxPeerReadMsgId(dialogId: dialogId, excluding: accountId)
            } else {
                peerReadMsgId = 0
            }
            let messagesById = Dictionary(uniqueKeysWithValues: messages.compactMap { message in
                message.msgId.map { ($0, message) }
            })
            lines = messages.map { message in
                let replyPreview = message.replyToMsgId.map { targetId in
                    guard let target = messagesById[targetId] else { return String(localized: "Earlier message") }
                    return target.state == "deleted_for_all" ? String(localized: "Deleted message") : target.text
                }
                return line(from: message, peerReadMsgId: peerReadMsgId, replyPreview: replyPreview)
            }
            let hasServerMessage = try await localStore.oldestServerMsgId(dialogId: dialogId) != nil
            canLoadEarlier = hasServerMessage && (historyHasMoreByDialog[dialogId] ?? true)
            await markReadIfNeeded(dialogId: dialogId, messages: messages)
        } catch {
            status = "Local load failed: \(error.localizedDescription)"
        }
    }

    private func line(from message: LocalMessage, peerReadMsgId: Int64, replyPreview: String?) -> Line {
        let mine = message.senderAccountId == storedSession?.session.accountId
        let deliveryState: Line.Delivery
        if mine, let msgId = message.msgId, msgId <= peerReadMsgId {
            deliveryState = .seen
        } else {
            deliveryState = delivery(from: message.localState)
        }
        return Line(
            id: message.localId,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            text: message.state == "deleted_for_all" ? String(localized: "Message deleted") : message.text,
            mine: mine,
            delivery: deliveryState,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            replyPreview: replyPreview,
            editVersion: message.editVersion,
            isEdited: message.editVersion > 0 && message.state == "visible",
            isDeleted: message.state == "deleted_for_all"
        )
    }

    private func dialog(from local: LocalDialog) -> Dialog {
        let title = displayTitle(local.title, fallback: shortDialogId(local.dialogId))
        let lastText = local.lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle: String
        if local.lastState == "deleted_for_all" {
            subtitle = String(localized: "Message deleted")
        } else if let lastText, !lastText.isEmpty {
            subtitle = lastText
        } else {
            subtitle = "No messages yet"
        }
        return Dialog(
            id: local.dialogId,
            title: title,
            subtitle: subtitle,
            updatedAt: local.lastServerTs ?? local.updatedAt,
            isPending: local.lastLocalState == "sending",
            unreadCount: local.unreadCount
        )
    }

    private func displayTitle(_ candidate: String?, fallback: String) -> String {
        let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? fallback : trimmed
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
        guard let token = storedSession?.session.token else { return }
        guard let accountId = storedSession?.session.accountId, let localStore else { return }
        guard let maxMsgId = messages.compactMap(\.msgId).max() else { return }

        do {
            let current = try await localStore.maxReadMsgId(dialogId: dialogId, accountId: accountId)
            guard maxMsgId > current else { return }
            let response = try await api.markRead(dialogId: dialogId, maxReadMsgId: maxMsgId, token: token)
            try await localStore.markRead(dialogId: response.dialogId, accountId: accountId, maxReadMsgId: response.maxReadMsgId)
            await refreshDialogs()
        } catch {
            // Read receipts are opportunistic; sync will retry after the next hint or reload.
        }
    }

    private func retryPendingOutbox() async {
        guard !retryInFlight else { return }
        guard let token = storedSession?.session.token, let localStore else { return }

        retryInFlight = true
        defer { retryInFlight = false }

        do {
            let items = try await localStore.pendingOutboxReady()
            guard !items.isEmpty else { return }

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
                    let nextRetryCount = item.retryCount + 1
                    let delay = retryDelay(forRetryCount: nextRetryCount)
                    try? await localStore.markFailed(clientMsgId: item.clientMsgId, retryAfter: delay)
                    if activeDialogId == item.dialogId {
                        await loadLocalLines(dialogId: item.dialogId)
                    }
                    await refreshDialogs()
                }
            }
        } catch {
            status = "Outbox retry failed: \(error.localizedDescription)"
        }
    }

    private func sendOutboxItem(_ item: PendingOutboxItem, token: String) async throws {
        let response = try await api.sendMessage(
            dialogId: item.dialogId,
            clientMsgId: item.clientMsgId,
            body: item.body,
            replyToMsgId: item.replyToMsgId,
            token: token
        )

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
        return try? await localStore.nextPendingOutboxDelay()
    }

    private func retryDelay(forRetryCount retryCount: Int) -> TimeInterval {
        min(30, pow(2, Double(max(0, retryCount - 1))))
    }

    private func upsert(_ message: CloudMessage) {
        let mine = message.senderAccountId == storedSession?.session.accountId
        if let index = lines.firstIndex(where: { $0.clientMsgId == message.clientMsgId }) {
            lines[index].dialogId = message.dialogId
            lines[index].msgId = message.msgId
            lines[index].text = message.text
            lines[index].replyToMsgId = message.replyToMsgId
            lines[index].editVersion = message.editVersion
            lines[index].isEdited = message.editVersion > 0 && message.state == "visible"
            lines[index].isDeleted = message.state == "deleted_for_all"
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
            text: message.text,
            mine: mine,
            delivery: .sent,
            timestamp: message.serverTs,
            replyToMsgId: message.replyToMsgId,
            editVersion: message.editVersion,
            isEdited: message.editVersion > 0 && message.state == "visible",
            isDeleted: message.state == "deleted_for_all"
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
            let token = storedSession?.session.token,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        do {
            let mutationId = UUID().uuidString.lowercased()
            let response = try await retryTransientMutation {
                try await self.api.editMessage(
                    dialogId: dialogId,
                    msgId: msgId,
                    clientMutationId: mutationId,
                    expectedEditVersion: line.editVersion,
                    body: text,
                    token: token
                )
            }
            try await localStore?.applyMessageMutation(response)
            draft = ""
            composerMode = .text
            await loadLocalLines(dialogId: dialogId)
            await refreshDialogs()
            status = response.duplicate ? "Edit confirmed" : "Edited"
            scheduleSync()
        } catch {
            status = "Edit failed: \(error.localizedDescription)"
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
            line.mine,
            !line.isDeleted,
            let token = storedSession?.session.token,
            let dialogId = line.dialogId,
            let msgId = line.msgId
        else { return }
        do {
            let mutationId = UUID().uuidString.lowercased()
            let response = try await retryTransientMutation {
                try await self.api.deleteMessage(
                    dialogId: dialogId,
                    msgId: msgId,
                    clientMutationId: mutationId,
                    token: token
                )
            }
            try await localStore?.applyMessageMutation(response)
            await loadLocalLines(dialogId: dialogId)
            await refreshDialogs()
            status = response.duplicate ? "Deletion confirmed" : "Message deleted"
            scheduleSync()
        } catch {
            status = "Delete failed: \(error.localizedDescription)"
        }
    }

    private func retryTransientMutation<T>(_ operation: () async throws -> T) async throws -> T {
        do {
            return try await operation()
        } catch let error as URLError where error.code == .timedOut || error.code == .networkConnectionLost {
            try await Task.sleep(for: .milliseconds(250))
            return try await operation()
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
        activeDialogId = nil
        draft = ""
        peerPhone = ""
        lines = []
        canLoadEarlier = false

        dialogs = [
            Dialog(id: "demo-mehrona", title: "Меҳрона", subtitle: "Биё, пагоҳ суҳбат мекунем", updatedAt: Self.demoTimestamp(minutesAgo: 2), isPending: false, unreadCount: 2, isPinned: true, mentionCount: 1),
            Dialog(id: "demo-firooz", title: "Фирӯз", subtitle: "Документы получил, спасибо", updatedAt: Self.demoTimestamp(minutesAgo: 23), isPending: false, unreadCount: 4, isMuted: true),
            Dialog(id: "demo-madina", title: "Мадина", subtitle: "Дар роҳам", updatedAt: Self.demoTimestamp(minutesAgo: 1_480), isPending: false, unreadCount: 0, draftPreview: "Пас аз даҳ дақиқа…"),
            Dialog(id: "demo-aziz", title: "Азиз", subtitle: "Созвонимся вечером?", updatedAt: Self.demoTimestamp(minutesAgo: 2_920), isPending: false, unreadCount: 0, isTyping: true),
        ]
        draftsByDialog = ["demo-madina": "Пас аз даҳ дақиқа…"]

        demoLinesByDialog = [
            "demo-mehrona": [
                demoLine(dialogId: "demo-mehrona", messageId: 1, text: "Салом! Имрӯз вақт дорӣ?", mine: false, minutesAgo: 9),
                demoLine(dialogId: "demo-mehrona", messageId: 2, text: "Салом 👋 Бале, баъди соати ҳафт.", mine: true, minutesAgo: 7, delivery: .seen),
                demoLine(dialogId: "demo-mehrona", messageId: 3, text: "Олично. Тогда напишу ближе к вечеру.", mine: false, minutesAgo: 4),
                demoLine(dialogId: "demo-mehrona", messageId: 4, text: "Хуб, мунтазир мешавам.", mine: true, minutesAgo: 2, delivery: .seen),
                Line(id: "demo-mehrona-5", dialogId: "demo-mehrona", msgId: 5, clientMsgId: "demo-mehrona-5", text: "Шоми Душанбе", mine: false, delivery: .sent, timestamp: Self.demoTimestamp(minutesAgo: 1), attachment: .photo(name: "Шоми Душанбе")),
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
    }

    private func sendDemo(_ text: String, replyPreview: String? = nil, attachment: DemoAttachment? = nil) {
        guard let dialogId = activeDialogId else { return }
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
        lines = demoLinesByDialog[dialogId] ?? []
        dialogs = dialogs.map { dialog in
            guard dialog.id == dialogId else { return dialog }
            var updated = dialog
            updated.subtitle = text
            updated.updatedAt = Self.demoTimestamp(minutesAgo: 0)
            updated.isPending = false
            updated.unreadCount = 0
            updated.draftPreview = nil
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
    #endif

    #if !DEBUG
    func reactToDemoMessage(_ lineId: String, reaction: String = "❤️") {}
    func deleteDemoMessage(_ lineId: String) {}
    func sendDemoAttachment(_ attachment: DemoAttachment, caption: String = "") {}
    func beginDemoRecording() {}
    func finishDemoRecording() {}
    #endif
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
