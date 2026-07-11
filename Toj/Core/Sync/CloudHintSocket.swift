import Foundation

struct SyncHint: Codable, Equatable, Sendable {
    let type: String
    let pts: Int64
    let ptsCount: Int64
}

actor CloudHintSocket {
    enum State: Equatable, Sendable {
        case disconnected
        case connecting
        case connected
    }

    private let url: URL
    private let token: String
    private let session: URLSession
    private var task: URLSessionWebSocketTask?
    private var runLoop: Task<Void, Never>?
    private var backoff = BackoffPolicy()
    private(set) var state: State = .disconnected

    private let hintsContinuation: AsyncStream<SyncHint>.Continuation
    nonisolated let hints: AsyncStream<SyncHint>

    init(url: URL, token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.url = url
        self.token = token
        self.session = session
        (hints, hintsContinuation) = AsyncStream.makeStream(of: SyncHint.self)
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

    private func run() async {
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            self.task = task
            state = .connecting
            task.resume()
            do {
                try await receiveLoop(on: task)
            } catch {
                // Reconnect below.
            }
            task.cancel(with: .abnormalClosure, reason: nil)
            state = .disconnected
            guard !Task.isCancelled else { return }
            let delay = backoff.nextDelay()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async throws {
        state = .connected
        while !Task.isCancelled {
            let message = try await task.receive()
            backoff.reset()
            guard let hint = Self.hint(from: message), hint.type == "sync_hint" else { continue }
            hintsContinuation.yield(hint)
        }
    }

    private nonisolated static func hint(from message: URLSessionWebSocketTask.Message) -> SyncHint? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return nil
        }
        return try? JSONDecoder().decode(SyncHint.self, from: data)
    }
}
