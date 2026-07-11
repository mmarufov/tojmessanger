import Foundation
import Observation
import UIKit

@MainActor
@Observable
final class CloudAppModel {
    struct Dialog: Identifiable, Equatable {
        let id: String
        let title: String
        let subtitle: String
        let updatedAt: String
        let isPending: Bool
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

    var phone = "+992 "
    var displayName = ""
    var code = ""
    var peerPhone = ""
    var draft = ""
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
        pushCenter: PushRegistrationCenter = .shared
    ) {
        self.api = CloudAPI(config: config)
        self.tokenStore = tokenStore
        self.pushCenter = pushCenter
        self.localStore = try? CloudLocalStore.default()
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

    func signOut() async {
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
        activeDialogId = dialogId
        await loadLocalLines(dialogId: dialogId)
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
        draft = ""
        await send(text)
    }

    private func send(_ text: String) async {
        guard let token = storedSession?.session.token, let dialogId = activeDialogId else { return }
        let clientMsgId = UUID().uuidString.lowercased()
        do {
            if let localStore, let accountId = storedSession?.session.accountId {
                _ = try await localStore.insertSending(
                    dialogId: dialogId,
                    clientMsgId: clientMsgId,
                    text: text,
                    senderAccountId: accountId
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
                    delivery: .sending
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
            if let dialogId = activeDialogId ?? dialogs.first?.id {
                activeDialogId = dialogId
                await loadLocalLines(dialogId: dialogId)
            }
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
                guard update.type == "message.new", let message = update.message else { continue }
                if activeDialogId == nil {
                    activeDialogId = message.dialogId
                }
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
        activeDialogId = try await localStore.latestDialogId()
        if let dialogId = activeDialogId {
            await loadLocalLines(dialogId: dialogId)
        } else {
            lines = []
            canLoadEarlier = false
        }
    }

    private func refreshDialogs() async {
        guard let localStore else { return }
        do {
            dialogs = try await localStore.dialogs().map(dialog(from:))
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
            lines = messages.map { line(from: $0, peerReadMsgId: peerReadMsgId) }
            let hasServerMessage = try await localStore.oldestServerMsgId(dialogId: dialogId) != nil
            canLoadEarlier = hasServerMessage && (historyHasMoreByDialog[dialogId] ?? true)
            await markReadIfNeeded(dialogId: dialogId, messages: messages)
        } catch {
            status = "Local load failed: \(error.localizedDescription)"
        }
    }

    private func line(from message: LocalMessage, peerReadMsgId: Int64) -> Line {
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
            text: message.text,
            mine: mine,
            delivery: deliveryState
        )
    }

    private func dialog(from local: LocalDialog) -> Dialog {
        let title = displayTitle(local.title, fallback: shortDialogId(local.dialogId))
        let lastText = local.lastText?.trimmingCharacters(in: .whitespacesAndNewlines)
        let subtitle: String
        if let lastText, !lastText.isEmpty {
            subtitle = lastText
        } else {
            subtitle = "No messages yet"
        }
        return Dialog(
            id: local.dialogId,
            title: title,
            subtitle: subtitle,
            updatedAt: local.lastServerTs ?? local.updatedAt,
            isPending: local.lastLocalState == "sending"
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
            lines[index].mine = mine
            lines[index].delivery = .sent
            return
        }
        lines.append(Line(
            id: message.id,
            dialogId: message.dialogId,
            msgId: message.msgId,
            clientMsgId: message.clientMsgId,
            text: message.text,
            mine: mine,
            delivery: .sent
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
