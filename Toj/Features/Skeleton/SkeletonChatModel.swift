import Foundation
import Observation

/// Glue for the walking skeleton: publish keys → connect socket → lazily
/// establish the E2E session → optimistic send/receive.
/// UI state lives on the main actor; crypto and networking never block it.
@MainActor
@Observable
final class SkeletonChatModel {
    struct Line: Identifiable, Equatable {
        let id: String
        let text: String
        let mine: Bool
        var acked: Bool
    }

    let me: String
    let peer: String
    private(set) var lines: [Line] = []
    private(set) var status = "starting…"

    private let engine: CryptoEngine
    private let socket: WebSocketClient
    private let keys: KeyDirectoryClient
    private var listenTask: Task<Void, Never>?

    init(me: String, peer: String, config: SkeletonConfig = .current) throws {
        self.me = me
        self.peer = peer
        self.engine = try CryptoEngine(userId: me)
        self.socket = WebSocketClient(url: config.wsURL(user: me))
        self.keys = KeyDirectoryClient(base: config.httpBase)
    }

    func start() async {
        do {
            let bundle = try await engine.makeLocalBundle()
            try await keys.publish(bundle, for: me)
            status = "keys published — connecting…"
        } catch {
            status = "key publish failed: \(error.localizedDescription)"
        }
        await socket.start()
        listenTask = Task { [weak self, socket] in
            for await envelope in socket.inbound {
                await self?.handle(envelope)
            }
        }
        status = "ready as \(me)"

        // Dev hook for scripted demos: TOJ_AUTOSEND=<text> sends after TOJ_AUTOSEND_DELAY
        // seconds (default 3), retrying until the peer's keys appear.
        let env = ProcessInfo.processInfo.environment
        if let text = env["TOJ_AUTOSEND"] {
            let delay = Double(env["TOJ_AUTOSEND_DELAY"] ?? "") ?? 3
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(delay))
                for _ in 0..<10 {
                    guard let self else { return }
                    await self.send(text)
                    if self.lines.contains(where: { $0.mine && $0.text == text }) { return }
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    func stop() async {
        listenTask?.cancel()
        listenTask = nil
        await socket.stop()
    }

    func send(_ text: String) async {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try await ensureSession()
            let sealed = try await engine.encrypt(trimmed, for: peer)
            let envelope = Envelope.message(
                from: me,
                to: peer,
                payloadType: sealed.type,
                payload: sealed.ciphertext
            )
            lines.append(Line(id: envelope.id, text: trimmed, mine: true, acked: false))
            await socket.send(envelope)
        } catch {
            status = "send failed: \(error.localizedDescription)"
        }
    }

    private func ensureSession() async throws {
        if try await engine.hasSession(with: peer) { return }
        status = "fetching \(peer)'s keys…"
        guard let bundle = try await keys.fetch(for: peer) else {
            status = "\(peer) hasn't published keys yet — start the other device, then retry"
            struct PeerNotRegistered: Error {}
            throw PeerNotRegistered()
        }
        try await engine.establishSession(with: peer, bundle: bundle)
        status = "E2E session established with \(peer)"
    }

    private func handle(_ envelope: Envelope) async {
        switch envelope.type {
        case .ack:
            if let index = lines.firstIndex(where: { $0.id == envelope.id }) {
                lines[index].acked = true
            }
        case .msg:
            guard let payloadType = envelope.payloadType, let payload = envelope.payload else { return }
            do {
                let text = try await engine.decrypt(type: payloadType, ciphertext: payload, from: envelope.from)
                lines.append(Line(id: envelope.id, text: text, mine: false, acked: true))
            } catch {
                status = "decrypt failed: \(error.localizedDescription)"
            }
        }
    }
}
