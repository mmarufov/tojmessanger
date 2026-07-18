import Foundation

nonisolated struct SyncHint: Codable, Equatable, Sendable {
    let type: String
    let pts: Int64
    let ptsCount: Int64
}

nonisolated struct CallHint: Codable, Equatable, Sendable {
    let type: String
    let callId: String
    let latestEventSeq: Int64
}

nonisolated struct SessionRevokedHint: Codable, Equatable, Sendable {
    let type: String
    let deviceId: String?
    let reason: String?
}

nonisolated enum CloudSocketEvent: Equatable, Sendable {
    case sync(SyncHint)
    case call(CallHint)
    case sessionRevoked(SessionRevokedHint)
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

    private let eventsContinuation: AsyncStream<CloudSocketEvent>.Continuation
    nonisolated let events: AsyncStream<CloudSocketEvent>

    init(url: URL, token: String, session: URLSession = URLSession(configuration: .ephemeral)) {
        self.url = url
        self.token = token
        self.session = session
        (events, eventsContinuation) = AsyncStream.makeStream(of: CloudSocketEvent.self)
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
            guard let event = Self.event(from: message) else { continue }
            eventsContinuation.yield(event)
        }
    }

    private nonisolated static func event(from message: URLSessionWebSocketTask.Message) -> CloudSocketEvent? {
        let data: Data
        switch message {
        case .string(let text): data = Data(text.utf8)
        case .data(let raw): data = raw
        @unknown default: return nil
        }
        guard let discriminator = try? JSONDecoder().decode(SocketDiscriminator.self, from: data) else {
            return nil
        }
        let decoder = JSONDecoder()
        switch discriminator.type {
        case "sync_hint":
            return (try? decoder.decode(SyncHint.self, from: data)).map(CloudSocketEvent.sync)
        case "call_hint":
            return (try? decoder.decode(CallHint.self, from: data)).map(CloudSocketEvent.call)
        case "session_revoked":
            return (try? decoder.decode(SessionRevokedHint.self, from: data)).map(CloudSocketEvent.sessionRevoked)
        default:
            return nil
        }
    }
}

private nonisolated struct SocketDiscriminator: Codable, Sendable {
    let type: String
}
