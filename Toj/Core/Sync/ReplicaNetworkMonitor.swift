import Foundation
import Network

nonisolated enum ReplicaNetworkClass: Equatable, Sendable {
    case unknown
    case offline
    case wifi
    case cellular
    case constrained
    case roaming
}

nonisolated struct ReplicaNetworkSnapshot: Equatable, Sendable {
    let networkClass: ReplicaNetworkClass
    let isExpensive: Bool
    let isConstrained: Bool
    let isRoaming: Bool

    var allowsEssentialSync: Bool { networkClass != .offline && networkClass != .unknown }
    var allowsDiscretionaryHydration: Bool {
        networkClass != .offline && networkClass != .unknown && !isConstrained && !isRoaming
    }

    var mediaNetworkClass: MediaNetworkClass {
        if isRoaming { return .roaming }
        return switch networkClass {
        case .wifi: .wifi
        case .cellular: .cellular
        case .unknown, .constrained, .offline: .constrained
        case .roaming: .roaming
        }
    }
}

/// A process-wide, lock-protected view of Network.framework state. It intentionally stores only
/// coarse local policy signals; no interface or carrier details are logged or uploaded.
nonisolated final class ReplicaNetworkMonitor: @unchecked Sendable {
    static let shared = ReplicaNetworkMonitor()

    /// Network.framework deliberately does not expose cellular roaming state. The app can feed the
    /// carrier/account signal it receives from its network settings layer here; persisting the
    /// coarse boolean lets background launches apply the safe policy before UI restoration. No
    /// carrier identity or location is stored or uploaded.
    private static let roamingDefaultsKey = "toj.network.cellular-roaming.v1"

    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "com.toj.replica-network", qos: .utility)
    private let lock = NSLock()
    private let defaults: UserDefaults
    private var cellularRoaming: Bool
    private var latestUsesCellular = false
    private var latest = ReplicaNetworkSnapshot(
        networkClass: .unknown,
        isExpensive: false,
        isConstrained: false,
        isRoaming: false
    )
    private var continuations: [UUID: AsyncStream<ReplicaNetworkSnapshot>.Continuation] = [:]

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.cellularRoaming = defaults.bool(forKey: Self.roamingDefaultsKey)
        monitor.pathUpdateHandler = { [weak self] path in
            self?.accept(path)
        }
        monitor.start(queue: queue)
    }

    deinit {
        monitor.cancel()
    }

    func snapshot() -> ReplicaNetworkSnapshot {
        lock.withLock { latest }
    }

    /// A multicast stream of coarse path changes. Every subscriber receives the current snapshot
    /// immediately, then all later transitions. This is the wake-up source for foreground sync and
    /// durable media work, so recovering Wi-Fi never requires a process relaunch.
    func updates() -> AsyncStream<ReplicaNetworkSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream.makeStream(of: ReplicaNetworkSnapshot.self)
        let current = lock.withLock {
            continuations[id] = continuation
            return latest
        }
        continuation.onTermination = { [weak self] _ in
            self?.removeContinuation(id)
        }
        continuation.yield(current)
        return stream
    }

    /// The user-controlled roaming override persisted for both foreground and background policy.
    /// Network.framework does not provide this value itself.
    func cellularRoamingSetting() -> Bool {
        lock.withLock { cellularRoaming }
    }

    /// Updates the coarse roaming signal supplied by the account/carrier layer. Passing `false`
    /// immediately restores ordinary cellular policy on the next snapshot.
    func setCellularRoaming(_ isRoaming: Bool) {
        let update: ReplicaNetworkSnapshot? = lock.withLock {
            cellularRoaming = isRoaming
            defaults.set(isRoaming, forKey: Self.roamingDefaultsKey)
            guard latestUsesCellular,
                  latest.networkClass != .offline,
                  latest.networkClass != .unknown else { return nil }
            let next = ReplicaNetworkSnapshot(
                networkClass: latest.isConstrained ? .constrained : (isRoaming ? .roaming : .cellular),
                isExpensive: latest.isExpensive,
                isConstrained: latest.isConstrained,
                isRoaming: isRoaming
            )
            guard next != latest else { return nil }
            latest = next
            return next
        }
        if let update { publish(update) }
    }

    private func accept(_ path: NWPath) {
        let update: ReplicaNetworkSnapshot? = lock.withLock {
            latestUsesCellular = path.usesInterfaceType(.cellular)
            let networkClass: ReplicaNetworkClass
            let roaming: Bool
            if path.status != .satisfied {
                networkClass = .offline
                roaming = false
            } else if path.isConstrained {
                networkClass = .constrained
                roaming = cellularRoaming && path.usesInterfaceType(.cellular)
            } else if path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet) {
                networkClass = .wifi
                roaming = false
            } else if cellularRoaming && path.usesInterfaceType(.cellular) {
                networkClass = .roaming
                roaming = true
            } else {
                networkClass = .cellular
                roaming = false
            }
            let next = ReplicaNetworkSnapshot(
                networkClass: networkClass,
                isExpensive: path.isExpensive,
                isConstrained: path.isConstrained,
                isRoaming: roaming
            )
            guard next != latest else { return nil }
            latest = next
            return next
        }
        if let update { publish(update) }
    }

    private func publish(_ snapshot: ReplicaNetworkSnapshot) {
        let subscribers = lock.withLock { Array(continuations.values) }
        subscribers.forEach { $0.yield(snapshot) }
    }

    private func removeContinuation(_ id: UUID) {
        _ = lock.withLock { continuations.removeValue(forKey: id) }
    }
}
