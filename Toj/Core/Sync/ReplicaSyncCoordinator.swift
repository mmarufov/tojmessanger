import Foundation

nonisolated enum ReplicaDeadlineResult<Value: Sendable>: Sendable {
    case value(Value)
    case timedOut
    case cancelled
}

nonisolated private final class ReplicaDeadlineGate<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<ReplicaDeadlineResult<Value>, Never>?
    private var resolution: ReplicaDeadlineResult<Value>?
    private var tasks: [Task<Void, Never>] = []

    func install(_ continuation: CheckedContinuation<ReplicaDeadlineResult<Value>, Never>) {
        let resolved = lock.withLock { () -> ReplicaDeadlineResult<Value>? in
            if let resolution { return resolution }
            self.continuation = continuation
            return nil
        }
        if let resolved { continuation.resume(returning: resolved) }
    }

    func attach(_ tasks: [Task<Void, Never>]) {
        let shouldCancel = lock.withLock { () -> Bool in
            if resolution != nil { return true }
            self.tasks = tasks
            return false
        }
        if shouldCancel { tasks.forEach { $0.cancel() } }
    }

    func resolve(_ result: ReplicaDeadlineResult<Value>) {
        let payload = lock.withLock { () -> (
            CheckedContinuation<ReplicaDeadlineResult<Value>, Never>?,
            [Task<Void, Never>]
        )? in
            guard resolution == nil else { return nil }
            resolution = result
            let payload = (continuation, tasks)
            continuation = nil
            tasks = []
            return payload
        }
        guard let payload else { return }
        payload.1.forEach { $0.cancel() }
        payload.0?.resume(returning: result)
    }
}

/// An unstructured deadline race: a timed-out operation is cancelled but never keeps the caller
/// waiting while cancellation-insensitive URL/SQL work unwinds.
nonisolated enum ReplicaDeadline {
    static func run<Value: Sendable>(
        for duration: Duration,
        operation: @escaping @Sendable () async -> Value
    ) async -> ReplicaDeadlineResult<Value> {
        let gate = ReplicaDeadlineGate<Value>()
        if Task.isCancelled { return .cancelled }
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                gate.install(continuation)
                let operationTask = Task {
                    gate.resolve(.value(await operation()))
                }
                let timeoutTask = Task {
                    do {
                        try await Task.sleep(for: duration)
                        gate.resolve(.timedOut)
                    } catch {
                        // The winning operation or parent cancellation owns resolution.
                    }
                }
                gate.attach([operationTask, timeoutTask])
            }
        } onCancel: {
            gate.resolve(.cancelled)
        }
    }
}

nonisolated enum ReplicaSyncTrigger: Equatable, Sendable {
    case foreground
    case manualRetry
    case pathRecovery
    case socketReconnect
    case push
    case hint
}

/// Owns foreground sync task lifetime away from the main actor. A manual retry invalidates and
/// replaces stale work immediately; ordinary hints coalesce into at most one follow-up pass.
actor ReplicaSyncCoordinator {
    typealias Runner = @MainActor @Sendable (_ generation: UInt64) async -> Void

    nonisolated struct State: Equatable, Sendable {
        let generation: UInt64
        let activeTrigger: ReplicaSyncTrigger?
        let followUpRequested: Bool
    }

    private let runner: Runner
    private var generation: UInt64 = 0
    private var activeTrigger: ReplicaSyncTrigger?
    private var followUpRequested = false
    private var task: Task<Void, Never>?

    init(runner: @escaping Runner) {
        self.runner = runner
    }

    func trigger(_ trigger: ReplicaSyncTrigger) {
        if task != nil {
            if trigger == .manualRetry {
                // A second retry tap belongs to the replacement already in flight.
                guard activeTrigger != .manualRetry else { return }
                start(trigger: trigger, replacingCurrent: true)
            } else {
                followUpRequested = true
            }
            return
        }
        start(trigger: trigger, replacingCurrent: false)
    }

    func isCurrent(_ candidate: UInt64) -> Bool {
        candidate == generation && task != nil && !Task.isCancelled
    }

    func state() -> State {
        State(
            generation: generation,
            activeTrigger: activeTrigger,
            followUpRequested: followUpRequested
        )
    }

    func waitUntilIdle() async {
        while let current = task {
            await current.value
        }
    }

    /// Invalidates without waiting. Used when the local replica becomes unsafe and no new sync may
    /// publish into it, even if cancelled SQL or URL work takes time to unwind.
    func invalidate() {
        generation &+= 1
        task?.cancel()
        task = nil
        activeTrigger = nil
        followUpRequested = false
    }

    /// Stops and joins the active task before authenticated local state is destroyed.
    func stop() async {
        generation &+= 1
        let previous = task
        previous?.cancel()
        task = nil
        activeTrigger = nil
        followUpRequested = false
        await previous?.value
    }

    private func start(trigger: ReplicaSyncTrigger, replacingCurrent: Bool) {
        generation &+= 1
        let runGeneration = generation
        if replacingCurrent { task?.cancel() }
        followUpRequested = false
        activeTrigger = trigger
        let runner = runner
        task = Task { [weak self] in
            await runner(runGeneration)
            await self?.finished(generation: runGeneration)
        }
    }

    private func finished(generation completedGeneration: UInt64) {
        guard generation == completedGeneration else { return }
        task = nil
        activeTrigger = nil
        guard followUpRequested else { return }
        followUpRequested = false
        start(trigger: .hint, replacingCurrent: false)
    }
}
