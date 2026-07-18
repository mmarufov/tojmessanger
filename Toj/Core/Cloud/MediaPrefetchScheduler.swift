import Foundation

nonisolated enum MediaPrefetchLane: Hashable, Sendable {
    case thumbnail
    case fullMedia
    case any

    var component: MediaDownloadComponent? {
        switch self {
        case .thumbnail: .thumbnail
        case .fullMedia: .fullMedia
        case .any: nil
        }
    }
}

/// A persistent foreground drain. Wakes are edge-triggered, but a single wake keeps claiming work
/// until the durable queue is empty. BGProcessing is only the continuation path after suspension.
actor MediaPrefetchScheduler {
    typealias Worker = @Sendable (MediaPrefetchLane) async -> Bool

    private let worker: Worker
    private var networkClass: ReplicaNetworkClass = .unknown
    private var foregrounded = false
    private var drainTask: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(worker: @escaping Worker) {
        self.worker = worker
    }

    func update(networkClass: ReplicaNetworkClass, foregrounded: Bool) {
        let networkChanged = self.networkClass != networkClass
        self.networkClass = networkClass
        self.foregrounded = foregrounded
        if !foregrounded || networkClass == .offline || networkClass == .unknown {
            generation &+= 1
            drainTask?.cancel()
            drainTask = nil
            return
        }
        if networkChanged || drainTask == nil { startDrain() }
    }

    func wake(networkClass: ReplicaNetworkClass? = nil) {
        if let networkClass { self.networkClass = networkClass }
        guard foregrounded,
              self.networkClass != .offline,
              self.networkClass != .unknown else { return }
        if drainTask == nil { startDrain() }
    }

    func stop() async {
        foregrounded = false
        generation &+= 1
        let task = drainTask
        task?.cancel()
        drainTask = nil
        await task?.value
    }

    /// Deterministic completion hook used by tests and by callers that must flush the foreground
    /// queue before handing execution to a background continuation.
    func waitUntilIdle() async {
        let task = drainTask
        await task?.value
    }

    private func startDrain() {
        generation &+= 1
        let runGeneration = generation
        let worker = worker
        drainTask = Task {
            await Self.drain(
                generation: runGeneration,
                lanes: lanes(for: networkClass),
                worker: worker,
                scheduler: self
            )
        }
    }

    private nonisolated static func drain(
        generation: UInt64,
        lanes: [MediaPrefetchLane],
        worker: @escaping Worker,
        scheduler: MediaPrefetchScheduler
    ) async {
        guard !lanes.isEmpty else {
            await scheduler.finished(generation: generation)
            return
        }
        while !Task.isCancelled {
            let madeProgress = await withTaskGroup(of: Bool.self, returning: Bool.self) { group in
                for lane in lanes {
                    group.addTask { await worker(lane) }
                }
                var any = false
                for await result in group { any = any || result }
                return any
            }
            guard madeProgress else { break }
            await Task.yield()
        }
        await scheduler.finished(generation: generation)
    }

    private func finished(generation: UInt64) {
        guard self.generation == generation else { return }
        drainTask = nil
    }

    private func lanes(for networkClass: ReplicaNetworkClass) -> [MediaPrefetchLane] {
        switch networkClass {
        case .wifi:
            [.fullMedia, .fullMedia, .thumbnail]
        case .cellular:
            [.fullMedia, .thumbnail]
        case .constrained, .roaming:
            [.any]
        case .unknown, .offline:
            []
        }
    }
}
