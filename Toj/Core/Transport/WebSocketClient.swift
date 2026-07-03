import Foundation

/// Reconnecting WebSocket transport for envelopes.
///
/// Design rules (see CLAUDE.md): the network is hostile — every send is optimistic,
/// unacked envelopes are resent after each reconnect, and the whole loop is cancellable.
actor WebSocketClient {
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    private let url: URL
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var backoff = BackoffPolicy()
    private(set) var state: State = .disconnected

    /// Outbound envelopes not yet acked by the relay, keyed by envelope id.
    private(set) var pending: [String: Envelope] = [:]
    /// Ids of inbound messages already delivered, so reconnect replays don't duplicate.
    private var seenInbound: Set<String> = []

    private let inboundContinuation: AsyncStream<Envelope>.Continuation
    nonisolated let inbound: AsyncStream<Envelope>

    init(url: URL, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.url = url
        self.session = session
        (inbound, inboundContinuation) = AsyncStream.makeStream(of: Envelope.self)
    }

    func start() {
        guard runLoop == nil else { return }
        runLoop = Task { await run() }
    }

    func stop() {
        runLoop?.cancel()
        runLoop = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        state = .disconnected
    }

    func send(_ envelope: Envelope) async {
        pending[envelope.id] = envelope
        await transmit(envelope)
    }

    private func transmit(_ envelope: Envelope) async {
        guard state == .connected, let task, let text = envelope.encodedString() else { return }
        // Failures are fine: the envelope stays in `pending` and is resent on reconnect.
        try? await task.send(.string(text))
    }

    private func run() async {
        while !Task.isCancelled {
            let task = session.webSocketTask(with: url)
            self.task = task
            state = .connecting
            task.resume()
            do {
                try await receiveLoop(on: task)
            } catch {
                // Connection failed or dropped; fall through to backoff.
            }
            task.cancel(with: .abnormalClosure, reason: nil)
            state = .disconnected
            guard !Task.isCancelled else { return }
            let delay = backoff.nextDelay()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async throws {
        // URLSessionWebSocketTask queues sends during the handshake, so flush
        // optimistically; if the handshake fails, receive() throws and we retry.
        state = .connected
        for envelope in pending.values.sorted(by: { $0.ts < $1.ts }) {
            await transmit(envelope)
        }
        while !Task.isCancelled {
            let message = try await task.receive()
            backoff.reset()
            guard let envelope = Self.envelope(from: message) else { continue }
            switch envelope.type {
            case .ack:
                pending.removeValue(forKey: envelope.id)
                inboundContinuation.yield(envelope)
            case .msg:
                guard seenInbound.insert(envelope.id).inserted else { continue }
                inboundContinuation.yield(envelope)
            }
        }
    }

    private nonisolated static func envelope(from message: URLSessionWebSocketTask.Message) -> Envelope? {
        switch message {
        case .string(let text): return Envelope.decoded(from: Data(text.utf8))
        case .data(let data): return Envelope.decoded(from: data)
        @unknown default: return nil
        }
    }
}
