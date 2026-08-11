import Foundation
import Observation

@MainActor
@Observable
final class PresenceCoordinator {
    struct PeerPresence: Equatable, Sendable {
        let accountId: String
        var online: Bool
        var lastSeenAt: String?
        var revision: Int64
    }

    private struct TypingLease: Equatable, Sendable {
        let actorAccountId: String
        let expiresAt: Date
    }

    private let api: CloudAPI
    private(set) var values: [String: PeerPresence] = [:]
    private(set) var typingRevision: UInt64 = 0
    private(set) var presenceRevision: UInt64 = 0

    @ObservationIgnored private weak var store: CloudLocalStore?
    @ObservationIgnored private var observerAccountId: String?
    @ObservationIgnored private var token: String?
    @ObservationIgnored private var socket: CloudHintSocket?
    @ObservationIgnored private var enabled = false
    @ObservationIgnored private var foregroundActive = true
    @ObservationIgnored private var transportConnected = false
    @ObservationIgnored private var knownDirectPeers = Set<String>()
    @ObservationIgnored private var typingLeasesByDialog: [String: [String: TypingLease]] = [:]
    @ObservationIgnored private var typingExpiryTask: Task<Void, Never>?
    @ObservationIgnored private var typingIdleTask: Task<Void, Never>?
    @ObservationIgnored private var localTypingDialogId: String?
    @ObservationIgnored private var lastTypingSentAt: Date?

    init(api: CloudAPI) {
        self.api = api
    }

    func configure(
        store: CloudLocalStore?,
        session: CloudSession?,
        enabled: Bool
    ) async {
        let identityChanged = observerAccountId != session?.accountId || token != session?.token
        if identityChanged {
            // Capability negotiation can finish after the authenticated hint socket has already
            // connected. Preserve that socket while replacing account-scoped state.
            let attachedSocket = socket
            await reset(clearCacheValues: true)
            socket = attachedSocket
            self.store = store
            observerAccountId = session?.accountId
            token = session?.token
            if let store, let accountId = session?.accountId,
               let cached = try? await store.loadPresenceCache(observerAccountId: accountId) {
                values = Dictionary(uniqueKeysWithValues: cached.map {
                    ($0.subjectAccountId, PeerPresence(
                        accountId: $0.subjectAccountId,
                        online: false,
                        lastSeenAt: $0.lastSeenAt,
                        revision: $0.revision
                    ))
                })
                presenceRevision &+= 1
            }
        } else {
            self.store = store
        }
        self.enabled = enabled
        guard enabled else {
            await stopLocalTyping()
            clearEphemeral()
            await socket?.setPresenceActive(false)
            return
        }
        if foregroundActive, transportConnected {
            await socket?.setPresenceActive(true)
            await refreshKnownPeers()
        }
    }

    func attach(socket: CloudHintSocket?) async {
        self.socket = socket
        if enabled, foregroundActive, transportConnected {
            await socket?.setPresenceActive(true)
        }
    }

    func setForegroundActive(_ active: Bool) async {
        foregroundActive = active
        guard enabled else { return }
        if active, transportConnected {
            await socket?.setPresenceActive(true)
            await refreshKnownPeers()
        } else {
            await stopLocalTyping()
            await socket?.setPresenceActive(false)
            clearEphemeral()
        }
    }

    func transportChanged(_ state: CloudHintSocket.State) async {
        transportConnected = state == .connected
        guard enabled else { return }
        if transportConnected, foregroundActive {
            await socket?.setPresenceActive(true)
            await refreshKnownPeers()
        } else if state == .disconnected {
            clearEphemeral()
        }
    }

    func refresh(accountIds: [String]) async {
        guard enabled, let token, let observerAccountId else { return }
        let requested = Set(accountIds.filter { $0 != observerAccountId })
        knownDirectPeers.formUnion(requested)
        guard transportConnected, !requested.isEmpty else { return }
        for chunk in requested.sorted().chunked(maximumCount: 200) {
            do {
                let response = try await api.queryPresence(accountIds: chunk, token: token)
                let returned = Set(response.presences.map(\.accountId))
                let hidden = chunk.filter { !returned.contains($0) }
                for presence in response.presences {
                    accept(presence)
                }
                if !hidden.isEmpty {
                    for accountId in hidden { values.removeValue(forKey: accountId) }
                    try? await store?.removePresenceCache(
                        observerAccountId: observerAccountId,
                        subjectAccountIds: hidden
                    )
                    presenceRevision &+= 1
                }
            } catch {
                if case .unsupportedServer = cloudFailureDisposition(error) {
                    self.enabled = false
                    clearEphemeral()
                }
            }
        }
    }

    func updateDirectPeers(_ accountIds: [String]) async {
        let next = Set(accountIds)
        let added = next.subtracting(knownDirectPeers)
        knownDirectPeers = next
        if !added.isEmpty { await refresh(accountIds: Array(added)) }
    }

    func handle(_ hint: PresenceUpdateHint) async {
        guard enabled else { return }
        accept(CloudPresence(
            accountId: hint.accountId,
            online: hint.online,
            lastSeenAt: hint.lastSeenAt,
            revision: hint.revision
        ))
    }

    func handle(_ hint: PresenceVisibilityHint) async {
        guard enabled, let observerAccountId else { return }
        if hint.visible {
            await refresh(accountIds: [hint.accountId])
        } else {
            values.removeValue(forKey: hint.accountId)
            try? await store?.removePresenceCache(
                observerAccountId: observerAccountId,
                subjectAccountIds: [hint.accountId]
            )
            presenceRevision &+= 1
        }
    }

    func handle(_ hint: TypingUpdateHint) {
        guard enabled, foregroundActive, transportConnected,
              hint.expiresInMs > 0, hint.expiresInMs <= 30_000 else { return }
        var leases = typingLeasesByDialog[hint.dialogId] ?? [:]
        if hint.active {
            leases[hint.typingSessionId] = TypingLease(
                actorAccountId: hint.actorAccountId,
                expiresAt: Date(timeIntervalSinceNow: TimeInterval(hint.expiresInMs) / 1_000)
            )
        } else {
            leases.removeValue(forKey: hint.typingSessionId)
        }
        if leases.isEmpty { typingLeasesByDialog.removeValue(forKey: hint.dialogId) }
        else { typingLeasesByDialog[hint.dialogId] = leases }
        typingRevision &+= 1
        scheduleTypingExpiry()
    }

    func typingAccountIds(dialogId: String) -> [String] {
        _ = typingRevision
        let now = Date()
        return Array(Set((typingLeasesByDialog[dialogId] ?? [:]).values.compactMap {
            $0.expiresAt > now ? $0.actorAccountId : nil
        })).sorted()
    }

    func presence(accountId: String) -> PeerPresence? {
        _ = presenceRevision
        guard var value = values[accountId] else { return nil }
        if !transportConnected { value.online = false }
        return value
    }

    func userEditedDraft(dialogId: String, text: String, focused: Bool) {
        guard enabled, foregroundActive, transportConnected, focused,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            stopLocalTypingSoon(dialogId: dialogId)
            return
        }
        let now = Date()
        let shouldSend = localTypingDialogId != dialogId
            || lastTypingSentAt == nil
            || now.timeIntervalSince(lastTypingSentAt!) >= 3
        if let previous = localTypingDialogId, previous != dialogId {
            stopLocalTypingSoon(dialogId: previous)
        }
        localTypingDialogId = dialogId
        if shouldSend {
            lastTypingSentAt = now
            Task { [weak self] in await self?.socket?.sendTyping(dialogId: dialogId, active: true) }
        }
        typingIdleTask?.cancel()
        typingIdleTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            await self?.stopLocalTyping(dialogId: dialogId)
        }
    }

    func composerFocusChanged(dialogId: String, focused: Bool, text: String) {
        // Focus alone is not user input. In particular, focusing a restored or remotely synced
        // non-empty draft must not announce typing.
        if !focused { stopLocalTypingSoon(dialogId: dialogId) }
    }

    func dialogDidChange(from dialogId: String) {
        stopLocalTypingSoon(dialogId: dialogId)
    }

    func stopLocalTyping(dialogId: String? = nil) async {
        guard let current = localTypingDialogId,
              dialogId == nil || dialogId == current else { return }
        typingIdleTask?.cancel()
        typingIdleTask = nil
        localTypingDialogId = nil
        lastTypingSentAt = nil
        await socket?.sendTyping(dialogId: current, active: false)
    }

    private func stopLocalTypingSoon(dialogId: String) {
        guard localTypingDialogId == dialogId else { return }
        typingIdleTask?.cancel()
        typingIdleTask = nil
        localTypingDialogId = nil
        lastTypingSentAt = nil
        let attachedSocket = socket
        Task { await attachedSocket?.sendTyping(dialogId: dialogId, active: false) }
    }

    func reset(clearCacheValues: Bool = false) async {
        await stopLocalTyping()
        await socket?.setPresenceActive(false)
        typingExpiryTask?.cancel()
        typingIdleTask?.cancel()
        typingExpiryTask = nil
        typingIdleTask = nil
        socket = nil
        enabled = false
        transportConnected = false
        knownDirectPeers.removeAll()
        typingLeasesByDialog.removeAll()
        typingRevision &+= 1
        if clearCacheValues {
            values.removeAll()
            presenceRevision &+= 1
            observerAccountId = nil
            token = nil
            store = nil
        }
    }

    #if DEBUG
    func enableFixturesForTesting(connected: Bool = true) {
        enabled = true
        foregroundActive = true
        transportConnected = connected
    }

    var localTypingDialogIdForTesting: String? { localTypingDialogId }
    #endif

    private func accept(_ presence: CloudPresence) {
        let currentRevision = values[presence.accountId]?.revision ?? -1
        guard presence.revision >= currentRevision else { return }
        let value = PeerPresence(
            accountId: presence.accountId,
            online: transportConnected && presence.online,
            lastSeenAt: presence.lastSeenAt,
            revision: presence.revision
        )
        values[presence.accountId] = value
        presenceRevision &+= 1
        if let observerAccountId {
            Task { [store] in
                try? await store?.savePresenceSnapshot(LocalPresenceSnapshot(
                    observerAccountId: observerAccountId,
                    subjectAccountId: presence.accountId,
                    lastSeenAt: presence.lastSeenAt,
                    revision: presence.revision
                ))
            }
        }
    }

    private func refreshKnownPeers() async {
        await refresh(accountIds: Array(knownDirectPeers))
    }

    private func clearEphemeral() {
        var changedPresence = false
        for accountId in values.keys where values[accountId]?.online == true {
            values[accountId]?.online = false
            changedPresence = true
        }
        if changedPresence { presenceRevision &+= 1 }
        if !typingLeasesByDialog.isEmpty {
            typingLeasesByDialog.removeAll()
            typingRevision &+= 1
        }
        typingExpiryTask?.cancel()
        typingExpiryTask = nil
    }

    private func scheduleTypingExpiry() {
        typingExpiryTask?.cancel()
        guard let next = typingLeasesByDialog.values
            .flatMap({ $0.values.map(\.expiresAt) })
            .min() else { return }
        typingExpiryTask = Task { [weak self] in
            let delay = max(0, next.timeIntervalSinceNow)
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self else { return }
            let now = Date()
            for dialogId in Array(self.typingLeasesByDialog.keys) {
                self.typingLeasesByDialog[dialogId] = self.typingLeasesByDialog[dialogId]?
                    .filter { $0.value.expiresAt > now }
                if self.typingLeasesByDialog[dialogId]?.isEmpty == true {
                    self.typingLeasesByDialog.removeValue(forKey: dialogId)
                }
            }
            self.typingRevision &+= 1
            self.scheduleTypingExpiry()
        }
    }
}

nonisolated enum TojPresenceFormatting {
    static func lastSeen(
        _ raw: String?,
        now: Date = Date(),
        calendar: Calendar = .current,
        locale: Locale = .current
    ) -> String {
        let fractionalFormatter = ISO8601DateFormatter()
        fractionalFormatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        guard let raw,
              let date = fractionalFormatter.date(from: raw)
                ?? ISO8601DateFormatter().date(from: raw) else {
            return String(localized: "status unavailable")
        }
        let time = DateFormatter()
        time.locale = locale
        time.calendar = calendar
        time.timeZone = calendar.timeZone
        time.timeStyle = .short
        time.dateStyle = .none
        let timeText = time.string(from: date)
        if calendar.isDate(date, inSameDayAs: now) {
            return String(format: String(localized: "last seen today at %@"), timeText)
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(date, inSameDayAs: yesterday) {
            return String(format: String(localized: "last seen yesterday at %@"), timeText)
        }
        let day = DateFormatter()
        day.locale = locale
        day.calendar = calendar
        day.timeZone = calendar.timeZone
        day.dateStyle = calendar.component(.year, from: date) == calendar.component(.year, from: now)
            ? .medium : .long
        day.timeStyle = .none
        return String(
            format: String(localized: "last seen %@ at %@"),
            day.string(from: date),
            timeText
        )
    }
}

nonisolated private extension Array {
    func chunked(maximumCount: Int) -> [[Element]] {
        guard maximumCount > 0 else { return [] }
        return stride(from: 0, to: count, by: maximumCount).map {
            Array(self[$0..<Swift.min($0 + maximumCount, count)])
        }
    }
}
