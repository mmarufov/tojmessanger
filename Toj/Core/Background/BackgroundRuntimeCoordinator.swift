import BackgroundTasks
import Foundation

nonisolated enum TojBackgroundTaskIdentifier {
    static let appRefresh = "com.toj.Toj.app-refresh"
    static let processing = "com.toj.Toj.processing"
    static let mediaSession = "com.toj.Toj.media-transfer"
}

nonisolated enum BackgroundWorkResult: Sendable {
    case completed
    case noData
    case retry

    fileprivate var succeeded: Bool {
        switch self {
        case .completed, .noData:
            true
        case .retry:
            false
        }
    }
}

nonisolated struct BackgroundWorkContext: Sendable {
    nonisolated enum Kind: Hashable, Sendable {
        case appRefresh
        case processing
    }

    let kind: Kind

    var isCancelled: Bool { Task.isCancelled }

    func checkCancellation() throws {
        try Task.checkCancellation()
    }
}

@MainActor
final class BackgroundRuntimeCoordinator {
    typealias WorkHandler = @Sendable (BackgroundWorkContext) async -> BackgroundWorkResult
    typealias BackgroundSessionEventsHandler = @MainActor @Sendable (String) -> Void

    static let shared = BackgroundRuntimeCoordinator()

    private var appRefreshHandler: WorkHandler?
    private var processingHandler: WorkHandler?
    private var sessionEventHandlers: [String: BackgroundSessionEventsHandler] = [:]
    private var pendingSessionEventIdentifiers: Set<String> = []
    private var sessionCompletionHandlers: [String: () -> Void] = [:]
    private var registered = false
    private struct PendingTask {
        let id: UUID
        let task: BGTask
        let completion: BackgroundTaskCompletion
    }
    private struct ActiveTask {
        let id: UUID
        let operation: Task<BackgroundWorkResult, Never>
        let completion: BackgroundTaskCompletion
    }
    private var pendingTasks: [BackgroundWorkContext.Kind: PendingTask] = [:]
    private var activeTasks: [BackgroundWorkContext.Kind: ActiveTask] = [:]

    private init() {}

    /// Registers every identifier listed in BGTaskSchedulerPermittedIdentifiers.
    /// This must run before application(_:didFinishLaunchingWithOptions:) returns.
    func registerTasks() {
        guard !registered else { return }
        registered = true

        let refreshRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: TojBackgroundTaskIdentifier.appRefresh,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                BackgroundRuntimeCoordinator.shared.run(task, kind: .appRefresh)
            }
        }
        let processingRegistered = BGTaskScheduler.shared.register(
            forTaskWithIdentifier: TojBackgroundTaskIdentifier.processing,
            using: .main
        ) { task in
            MainActor.assumeIsolated {
                BackgroundRuntimeCoordinator.shared.run(task, kind: .processing)
            }
        }

        assert(refreshRegistered, "App refresh task identifier is missing from Info.plist")
        assert(processingRegistered, "Processing task identifier is missing from Info.plist")
    }

    /// Installs application work without coupling the lifecycle layer to CloudAppModel.
    /// Handlers must cooperate with cancellation and persist their own resumable cursors.
    func installWorkHandlers(
        appRefresh: WorkHandler?,
        processing: WorkHandler?
    ) {
        appRefreshHandler = appRefresh
        processingHandler = processing
        startPendingTaskIfPossible(kind: .appRefresh)
        startPendingTaskIfPossible(kind: .processing)
    }

    func removeWorkHandlers() {
        _ = cancelInstalledWork()
    }

    /// Logout uses this variant so SQLCipher/media files are never destroyed while a system-
    /// launched operation still has a reference to the local replica.
    func removeWorkHandlersAndWait() async {
        let operations = cancelInstalledWork()
        for operation in operations {
            _ = await operation.value
        }
        cancelScheduledRequests()
    }

    /// A cold launch can discover that there is no authenticated replica to service old requests.
    /// Complete those system tasks promptly instead of retaining them until iOS expires the process.
    func completePendingTasksWithNoData() {
        let pending = Array(pendingTasks.values)
        pendingTasks.removeAll(keepingCapacity: false)
        for item in pending { item.completion.finish(success: true) }
    }

    @discardableResult
    func scheduleAppRefresh(
        earliestBeginDate: Date = Date(timeIntervalSinceNow: 15 * 60)
    ) -> Bool {
        let request = BGAppRefreshTaskRequest(identifier: TojBackgroundTaskIdentifier.appRefresh)
        request.earliestBeginDate = earliestBeginDate
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    @discardableResult
    func scheduleProcessing(
        earliestBeginDate: Date = Date(timeIntervalSinceNow: 60 * 60),
        requiresNetworkConnectivity: Bool = true,
        requiresExternalPower: Bool = false
    ) -> Bool {
        let request = BGProcessingTaskRequest(identifier: TojBackgroundTaskIdentifier.processing)
        request.earliestBeginDate = earliestBeginDate
        request.requiresNetworkConnectivity = requiresNetworkConnectivity
        request.requiresExternalPower = requiresExternalPower
        do {
            try BGTaskScheduler.shared.submit(request)
            return true
        } catch {
            return false
        }
    }

    func schedulePendingWork() {
        if appRefreshHandler != nil {
            scheduleAppRefresh()
        }
        if processingHandler != nil {
            scheduleProcessing()
        }
    }

    /// Installs the callback that recreates a background URLSession after iOS relaunches the app.
    /// If UIKit delivered the identifier first, the callback is replayed immediately on install.
    func installBackgroundSessionEventsHandler(
        identifier: String,
        handler: @escaping BackgroundSessionEventsHandler
    ) {
        sessionEventHandlers[identifier] = handler
        if pendingSessionEventIdentifiers.contains(identifier) {
            handler(identifier)
        }
    }

    func removeBackgroundSessionEventsHandler(identifier: String) {
        sessionEventHandlers.removeValue(forKey: identifier)
        // Explicit logout cancels the underlying session. Do not leave UIKit's cold-launch
        // completion handler retained if no further delegate callback will be delivered.
        pendingSessionEventIdentifiers.remove(identifier)
        sessionCompletionHandlers.removeValue(forKey: identifier)?()
    }

    /// Called by UIApplicationDelegate when pending background URLSession events wake the app.
    func receiveBackgroundSessionEvents(
        identifier: String,
        completionHandler: @escaping () -> Void
    ) {
        if let staleCompletion = sessionCompletionHandlers.updateValue(
            completionHandler,
            forKey: identifier
        ) {
            staleCompletion()
        }
        pendingSessionEventIdentifiers.insert(identifier)
        sessionEventHandlers[identifier]?(identifier)
    }

    /// The URLSession delegate must call this from urlSessionDidFinishEvents(forBackgroundURLSession:).
    func finishBackgroundSessionEvents(identifier: String) {
        pendingSessionEventIdentifiers.remove(identifier)
        sessionCompletionHandlers.removeValue(forKey: identifier)?()
    }

    private func run(_ task: BGTask, kind: BackgroundWorkContext.Kind) {
        let completion = BackgroundTaskCompletion(task: task)
        guard let handler = handler(for: kind) else {
            let pending = PendingTask(id: UUID(), task: task, completion: completion)
            if let replaced = pendingTasks.updateValue(pending, forKey: kind) {
                replaced.completion.finish(success: false)
            }
            task.expirationHandler = { [pendingID = pending.id] in
                Task { @MainActor in
                    BackgroundRuntimeCoordinator.shared.expirePendingTask(
                        kind: kind,
                        id: pendingID
                    )
                }
            }
            return
        }

        switch kind {
        case .appRefresh:
            scheduleAppRefresh()
        case .processing:
            scheduleProcessing()
        }

        execute(task: task, completion: completion, kind: kind, handler: handler)
    }

    private func startPendingTaskIfPossible(kind: BackgroundWorkContext.Kind) {
        guard let handler = handler(for: kind), let pending = pendingTasks.removeValue(forKey: kind) else {
            return
        }
        execute(
            task: pending.task,
            completion: pending.completion,
            kind: kind,
            handler: handler
        )
    }

    private func expirePendingTask(kind: BackgroundWorkContext.Kind, id: UUID) {
        guard let pending = pendingTasks[kind], pending.id == id else { return }
        pendingTasks.removeValue(forKey: kind)
        pending.completion.finish(success: false)
    }

    private func execute(
        task: BGTask,
        completion: BackgroundTaskCompletion,
        kind: BackgroundWorkContext.Kind,
        handler: @escaping WorkHandler
    ) {
        let id = UUID()
        let operation = Task.detached(priority: .utility) {
            await handler(BackgroundWorkContext(kind: kind))
        }
        let active = ActiveTask(id: id, operation: operation, completion: completion)
        if let replaced = activeTasks.updateValue(active, forKey: kind) {
            replaced.operation.cancel()
            replaced.completion.finish(success: false)
        }
        task.expirationHandler = {
            operation.cancel()
            completion.finish(success: false)
            Task { @MainActor in
                BackgroundRuntimeCoordinator.shared.removeActiveTask(kind: kind, id: id)
            }
        }
        Task { [weak self] in
            let result = await operation.value
            self?.finishActiveTask(
                kind: kind,
                id: id,
                result: result,
                wasCancelled: operation.isCancelled
            )
        }
    }

    private func finishActiveTask(
        kind: BackgroundWorkContext.Kind,
        id: UUID,
        result: BackgroundWorkResult,
        wasCancelled: Bool
    ) {
        guard let active = activeTasks[kind], active.id == id else { return }
        activeTasks.removeValue(forKey: kind)
        active.completion.finish(success: result.succeeded && !wasCancelled)
    }

    private func removeActiveTask(kind: BackgroundWorkContext.Kind, id: UUID) {
        guard activeTasks[kind]?.id == id else { return }
        activeTasks.removeValue(forKey: kind)
    }

    private func cancelInstalledWork() -> [Task<BackgroundWorkResult, Never>] {
        appRefreshHandler = nil
        processingHandler = nil
        cancelScheduledRequests()

        let pending = Array(pendingTasks.values)
        pendingTasks.removeAll(keepingCapacity: false)
        for item in pending { item.completion.finish(success: false) }

        let active = Array(activeTasks.values)
        activeTasks.removeAll(keepingCapacity: false)
        for item in active {
            item.operation.cancel()
            item.completion.finish(success: false)
        }
        return active.map(\.operation)
    }

    private func cancelScheduledRequests() {
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: TojBackgroundTaskIdentifier.appRefresh)
        BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: TojBackgroundTaskIdentifier.processing)
    }

    private func handler(for kind: BackgroundWorkContext.Kind) -> WorkHandler? {
        switch kind {
        case .appRefresh:
            appRefreshHandler
        case .processing:
            processingHandler
        }
    }
}

private final class BackgroundTaskCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private let task: BGTask
    private var finished = false

    init(task: BGTask) {
        self.task = task
    }

    func finish(success: Bool) {
        lock.lock()
        guard !finished else {
            lock.unlock()
            return
        }
        finished = true
        lock.unlock()
        task.setTaskCompleted(success: success)
    }
}
