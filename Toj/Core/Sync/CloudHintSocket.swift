import Foundation

nonisolated struct SyncHint: Codable, Equatable, Sendable {
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
    private let statesContinuation: AsyncStream<State>.Continuation
    nonisolated let states: AsyncStream<State>

    init(url: URL, token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.url = url
        self.token = token
        self.session = session
        (hints, hintsContinuation) = AsyncStream.makeStream(of: SyncHint.self)
        (states, statesContinuation) = AsyncStream.makeStream(of: State.self)
        statesContinuation.yield(.disconnected)
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
        setState(.disconnected)
    }

    private func run() async {
        while !Task.isCancelled {
            var request = URLRequest(url: url)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let task = session.webSocketTask(with: request)
            self.task = task
            setState(.connecting)
            task.resume()
            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    group.addTask { [weak self, task] in
                        guard let self else { return }
                        try await self.receiveLoop(on: task)
                    }
                    group.addTask { [weak self, task] in
                        guard let self else { return }
                        try await self.heartbeatLoop(on: task)
                    }
                    _ = try await group.next()
                    group.cancelAll()
                }
            } catch {
                // Reconnect below.
            }
            task.cancel(with: .abnormalClosure, reason: nil)
            setState(.disconnected)
            guard !Task.isCancelled else { return }
            let delay = backoff.nextDelay()
            try? await Task.sleep(for: .seconds(delay))
        }
    }

    private func receiveLoop(on task: URLSessionWebSocketTask) async throws {
        setState(.connected)
        while !Task.isCancelled {
            let message = try await task.receive()
            backoff.reset()
            guard let hint = Self.hint(from: message), hint.type == "sync_hint" else { continue }
            hintsContinuation.yield(hint)
        }
    }

    private func heartbeatLoop(on task: URLSessionWebSocketTask) async throws {
        while !Task.isCancelled {
            try await Task.sleep(for: .seconds(25))
            try Task.checkCancellation()
            try await Self.awaitPong(on: task)
        }
    }

    private nonisolated static func awaitPong(on task: URLSessionWebSocketTask) async throws {
        let stream = AsyncThrowingStream<Void, Error> { continuation in
            task.sendPing { error in
                if let error { continuation.finish(throwing: error) }
                else { continuation.finish() }
            }
            Task {
                do {
                    try await Task.sleep(for: .seconds(10))
                    continuation.finish(throwing: URLError(.timedOut))
                } catch {
                    // The stream already completed or its parent was cancelled.
                }
            }
        }
        for try await _ in stream {}
    }

    private func setState(_ next: State) {
        guard state != next else { return }
        state = next
        statesContinuation.yield(next)
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
