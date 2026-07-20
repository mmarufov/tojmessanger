import Foundation

/// The validated plaintext returned by one server media-chunk request. It exists in memory only;
/// the processor installed by `CloudMediaTransferEngine` seals it into `EncryptedMediaCache`
/// before the durable job cursor advances.
nonisolated struct BackgroundMediaDownloadedChunk: Sendable {
    let mediaId: String
    let offset: Int64
    let data: Data
    let nextOffset: Int64
    let totalSize: Int64
}

/// Token-free state for a user-started full-media download. The bearer credential remains solely
/// in the system-owned URLSession request; it is never encoded into Toj's durable metadata.
nonisolated struct BackgroundMediaDownloadJobMetadata: Codable, Equatable, Sendable {
    let id: String
    let mediaId: String
    var currentOffset: Int64
    let expectedTotalSize: Int64
    let createdAt: Date
    var retryCount: Int
    var nextRetryAt: Date?

    init(
        id: String = UUID().uuidString.lowercased(),
        mediaId: String,
        currentOffset: Int64,
        expectedTotalSize: Int64,
        createdAt: Date = Date(),
        retryCount: Int = 0,
        nextRetryAt: Date? = nil
    ) {
        self.id = id
        self.mediaId = mediaId
        self.currentOffset = currentOffset
        self.expectedTotalSize = expectedTotalSize
        self.createdAt = createdAt
        self.retryCount = retryCount
        self.nextRetryAt = nextRetryAt
    }
}

nonisolated enum BackgroundMediaChunkValidator {
    static let maximumChunkBytes = 1024 * 1024
    static let maximumMediaBytes: Int64 = 25 * 1024 * 1024

    static func validate(
        mediaId: String,
        requestedOffset: Int64,
        expectedTotalSize: Int64,
        data: Data,
        statusCode: Int,
        nextOffsetHeader: String?,
        totalSizeHeader: String?
    ) throws -> BackgroundMediaDownloadedChunk {
        guard (200..<300).contains(statusCode) else {
            throw CloudAPIError(
                status: statusCode,
                message: "HTTP \(statusCode)",
                retryAfter: nil
            )
        }
        guard
            let nextOffsetHeader,
            let nextOffset = Int64(nextOffsetHeader),
            let totalSizeHeader,
            let totalSize = Int64(totalSizeHeader),
            requestedOffset >= 0,
            expectedTotalSize > 0,
            expectedTotalSize <= maximumMediaBytes,
            totalSize == expectedTotalSize,
            !data.isEmpty,
            data.count <= maximumChunkBytes,
            nextOffset == requestedOffset + Int64(data.count),
            nextOffset <= totalSize
        else {
            throw CloudAPIError(status: -1, message: "Invalid media response", retryAfter: nil)
        }
        return BackgroundMediaDownloadedChunk(
            mediaId: mediaId,
            offset: requestedOffset,
            data: data,
            nextOffset: nextOffset,
            totalSize: totalSize
        )
    }
}

nonisolated enum BackgroundMediaTransferError: Error, LocalizedError, Sendable {
    case invalidJob
    case unreadableDownload
    case missingCredential

    var errorDescription: String? {
        switch self {
        case .invalidJob:
            String(localized: "The media download could not be resumed")
        case .unreadableDownload:
            String(localized: "The downloaded media could not be read")
        case .missingCredential:
            String(localized: "Open Toj to continue this media download")
        }
    }
}

/// Owns Toj's one background URLSession and chains the server's offset-addressed chunks until a
/// user-requested file is complete. Jobs survive process death. The caller's processor must write
/// each validated chunk to encrypted storage; the job cursor is committed only after that succeeds.
actor BackgroundMediaTransferSession {
    typealias ChunkProcessor = @Sendable (BackgroundMediaDownloadedChunk) async throws -> Void
    typealias ProgressHandler = @Sendable (Double) async -> Void

    nonisolated static let identifier = TojBackgroundTaskIdentifier.mediaSession

    fileprivate struct DownloadCompletion: Sendable {
        let jobId: String?
        let requestedOffset: Int64?
        let data: Data?
        let statusCode: Int?
        let nextOffsetHeader: String?
        let totalSizeHeader: String?
        let authorizationHeader: String?
        let transportErrorCode: Int?
    }

    private struct DownloadWaiter {
        let continuation: CheckedContinuation<Void, any Error>
        let progress: ProgressHandler
    }

    private let config: CloudConfig
    private let metadataURLOverride: URL?
    private var jobs: [String: BackgroundMediaDownloadJobMetadata] = [:]
    private var activeTaskIdentifiers: [String: Int] = [:]
    private var waiters: [String: [String: DownloadWaiter]] = [:]
    private var processor: ChunkProcessor?
    private var processorWaiters: [CheckedContinuation<ChunkProcessor, Never>] = []
    private var session: URLSession?
    private var delegate: BackgroundMediaURLSessionDelegate?
    private var started = false

    init(config: CloudConfig = .current, metadataURL: URL? = nil) {
        self.config = config
        self.metadataURLOverride = metadataURL
    }

    nonisolated static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.background(withIdentifier: identifier)
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.waitsForConnectivity = true
        configuration.allowsCellularAccess = true
        configuration.sessionSendsLaunchEvents = true
        configuration.isDiscretionary = false
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 24 * 60 * 60
        configuration.httpMaximumConnectionsPerHost = 2
        return configuration
    }

    /// Installs the encrypted-cache sink. This is intentionally separate from initialization so
    /// `CloudMediaTransferEngine` can finish actor initialization before its closure captures self.
    func installProcessor(_ processor: @escaping ChunkProcessor) async throws {
        self.processor = processor
        let pending = processorWaiters
        processorWaiters.removeAll(keepingCapacity: false)
        for waiter in pending { waiter.resume(returning: processor) }
        try await ensureStarted()
    }

    /// Starts or joins a complete user-requested download. Cancelling this waiter does not cancel
    /// the URLSession job: the explicit user action is allowed to finish while Toj is backgrounded.
    func downloadFullMedia(
        mediaId: String,
        cachedOffset: Int64,
        expectedTotalSize: Int64,
        token: String,
        progress: @escaping ProgressHandler = { _ in }
    ) async throws {
        guard
            UUID(uuidString: mediaId) != nil,
            cachedOffset >= 0,
            expectedTotalSize > 0,
            expectedTotalSize <= BackgroundMediaChunkValidator.maximumMediaBytes,
            cachedOffset <= expectedTotalSize,
            !token.isEmpty
        else { throw BackgroundMediaTransferError.invalidJob }
        guard cachedOffset < expectedTotalSize else { return }
        try await ensureStarted()

        let jobId: String
        if let existing = jobs.values.first(where: {
            $0.mediaId == mediaId && $0.expectedTotalSize == expectedTotalSize
        }) {
            jobId = existing.id
            if activeTaskIdentifiers[jobId] == nil {
                var resumed = existing
                // The encrypted cache is authoritative if a crash occurred between sealing a chunk
                // and advancing this small metadata record.
                resumed.currentOffset = cachedOffset
                jobs[jobId] = resumed
                try persistJobs()
                try startTask(job: resumed, authorizationHeader: "Bearer \(token)")
            }
        } else {
            let job = BackgroundMediaDownloadJobMetadata(
                mediaId: mediaId,
                currentOffset: cachedOffset,
                expectedTotalSize: expectedTotalSize
            )
            jobs[job.id] = job
            try persistJobs()
            try startTask(job: job, authorizationHeader: "Bearer \(token)")
            jobId = job.id
        }

        let waiterId = UUID().uuidString.lowercased()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                waiters[jobId, default: [:]][waiterId] = DownloadWaiter(
                    continuation: continuation,
                    progress: progress
                )
            }
        } onCancel: {
            Task { await self.cancelWaiter(jobId: jobId, waiterId: waiterId) }
        }
    }

    func persistedJobsForTesting() async throws -> [BackgroundMediaDownloadJobMetadata] {
        try await ensureStarted()
        return jobs.values.sorted { $0.createdAt < $1.createdAt }
    }

    /// Explicit logout must revoke system-owned requests that can still carry the old session
    /// credential, then erase Toj's token-free resume metadata.
    func cancelAllAndDeleteMetadata() async {
        // After process death `URLSession` still owns its requests while this actor is new. Recreate
        // the identified session first so explicit logout can cancel those credential-bearing tasks.
        try? await ensureStarted(resumesExistingTasks: false)
        if let session {
            for task in await session.allTasks { task.cancel() }
            session.invalidateAndCancel()
        }
        let jobIds = Array(jobs.keys)
        jobs.removeAll(keepingCapacity: false)
        activeTaskIdentifiers.removeAll(keepingCapacity: false)
        for jobId in jobIds {
            resumeWaiters(jobId: jobId, result: .failure(CancellationError()))
        }
        if let url = try? metadataURL() {
            try? FileManager.default.removeItem(at: url)
        }
        let waitingForProcessor = processorWaiters
        processorWaiters.removeAll(keepingCapacity: false)
        let cancelledProcessor: ChunkProcessor = { _ in throw CancellationError() }
        for waiter in waitingForProcessor { waiter.resume(returning: cancelledProcessor) }
        processor = nil
        session = nil
        delegate = nil
        started = false
        await MainActor.run {
            BackgroundRuntimeCoordinator.shared.removeBackgroundSessionEventsHandler(
                identifier: Self.identifier
            )
        }
    }

    private func ensureStarted(resumesExistingTasks: Bool = true) async throws {
        guard !started else { return }
        started = true
        do {
            jobs = Dictionary(uniqueKeysWithValues: try loadJobs().map { ($0.id, $0) })
            let delegate = BackgroundMediaURLSessionDelegate(owner: self)
            let session = URLSession(
                configuration: Self.makeConfiguration(),
                delegate: delegate,
                delegateQueue: delegate.operationQueue
            )
            self.delegate = delegate
            self.session = session

            await MainActor.run {
                BackgroundRuntimeCoordinator.shared.installBackgroundSessionEventsHandler(
                    identifier: Self.identifier
                ) { [weak self] _ in
                    guard let self else { return }
                    Task { try? await self.ensureStarted() }
                }
            }
            let existingTasks = await session.allTasks
            for task in existingTasks {
                guard
                    let jobId = task.taskDescription,
                    jobs[jobId] != nil,
                    task is URLSessionDownloadTask
                else {
                    task.cancel()
                    continue
                }
                activeTaskIdentifiers[jobId] = task.taskIdentifier
                task.priority = URLSessionTask.highPriority
                if resumesExistingTasks, task.state == .suspended { task.resume() }
            }
        } catch {
            started = false
            throw error
        }
    }

    private func startTask(
        job: BackgroundMediaDownloadJobMetadata,
        authorizationHeader: String
    ) throws {
        guard let session else { throw BackgroundMediaTransferError.invalidJob }
        var components = URLComponents(
            url: config.httpURL(path: "v1/media/\(job.mediaId)/chunks"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "offset", value: String(job.currentOffset)),
        ]
        guard let url = components?.url else { throw BackgroundMediaTransferError.invalidJob }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue(authorizationHeader, forHTTPHeaderField: "Authorization")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Accept")
        let task = session.downloadTask(with: request)
        task.taskDescription = job.id
        task.priority = URLSessionTask.highPriority
        activeTaskIdentifiers[job.id] = task.taskIdentifier
        task.resume()
    }

    fileprivate func receive(_ completion: DownloadCompletion) async {
        guard
            let jobId = completion.jobId,
            var job = jobs[jobId],
            let requestedOffset = completion.requestedOffset,
            requestedOffset == job.currentOffset
        else { return }
        activeTaskIdentifiers[jobId] = nil
        do {
            if let code = completion.transportErrorCode {
                throw URLError(URLError.Code(rawValue: code))
            }
            guard let data = completion.data, let statusCode = completion.statusCode else {
                throw BackgroundMediaTransferError.unreadableDownload
            }
            let chunk = try BackgroundMediaChunkValidator.validate(
                mediaId: job.mediaId,
                requestedOffset: requestedOffset,
                expectedTotalSize: job.expectedTotalSize,
                data: data,
                statusCode: statusCode,
                nextOffsetHeader: completion.nextOffsetHeader,
                totalSizeHeader: completion.totalSizeHeader
            )
            let processor = await resolvedProcessor()
            try await processor(chunk)
            await reportProgress(
                jobId: jobId,
                value: Double(chunk.nextOffset) / Double(max(1, job.expectedTotalSize))
            )

            if chunk.nextOffset == job.expectedTotalSize {
                jobs[jobId] = nil
                try persistJobs()
                resumeWaiters(jobId: jobId, result: .success(()))
                return
            }

            job.currentOffset = chunk.nextOffset
            job.retryCount = 0
            job.nextRetryAt = nil
            jobs[jobId] = job
            try persistJobs()
            guard let authorizationHeader = completion.authorizationHeader, !authorizationHeader.isEmpty else {
                throw BackgroundMediaTransferError.missingCredential
            }
            try startTask(job: job, authorizationHeader: authorizationHeader)
        } catch {
            job.retryCount += 1
            if
                case let .transient(retryAfter) = cloudFailureDisposition(error),
                job.retryCount <= 3,
                let authorizationHeader = completion.authorizationHeader,
                !authorizationHeader.isEmpty
            {
                let delay = retryAfter ?? min(4, pow(2, Double(job.retryCount - 1)))
                job.nextRetryAt = Date().addingTimeInterval(delay)
                jobs[jobId] = job
                try? persistJobs()
                try? await Task.sleep(for: .seconds(delay))
                guard jobs[jobId] != nil, activeTaskIdentifiers[jobId] == nil else { return }
                job.nextRetryAt = nil
                jobs[jobId] = job
                try? persistJobs()
                do {
                    try startTask(job: job, authorizationHeader: authorizationHeader)
                    return
                } catch {
                    // Fall through and expose a resumable paused job to the caller.
                }
            }
            jobs[jobId] = job
            try? persistJobs()
            resumeWaiters(jobId: jobId, result: .failure(error))
        }
    }

    fileprivate func finishedDeliveringBackgroundEvents() async {
        await MainActor.run {
            BackgroundRuntimeCoordinator.shared.finishBackgroundSessionEvents(
                identifier: Self.identifier
            )
        }
    }

    private func resolvedProcessor() async -> ChunkProcessor {
        if let processor { return processor }
        return await withCheckedContinuation { continuation in
            processorWaiters.append(continuation)
        }
    }

    private func cancelWaiter(jobId: String, waiterId: String) {
        guard let waiter = waiters[jobId]?[waiterId] else { return }
        waiters[jobId]?[waiterId] = nil
        if waiters[jobId]?.isEmpty == true { waiters[jobId] = nil }
        waiter.continuation.resume(throwing: CancellationError())
    }

    private func reportProgress(jobId: String, value: Double) async {
        let handlers = waiters[jobId]?.values.map(\.progress) ?? []
        for handler in handlers { await handler(min(1, max(0, value))) }
    }

    private func resumeWaiters(
        jobId: String,
        result: Result<Void, any Error>
    ) {
        let waiting: [DownloadWaiter]
        if let values = waiters.removeValue(forKey: jobId)?.values {
            waiting = Array(values)
        } else {
            waiting = []
        }
        for waiter in waiting {
            switch result {
            case .success:
                waiter.continuation.resume()
            case let .failure(error):
                waiter.continuation.resume(throwing: error)
            }
        }
    }

    private func metadataURL() throws -> URL {
        if let metadataURLOverride { return metadataURLOverride }
        let support = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return support
            .appending(path: "Toj", directoryHint: .isDirectory)
            .appending(path: "background-media-jobs.json")
    }

    private func loadJobs() throws -> [BackgroundMediaDownloadJobMetadata] {
        let url = try metadataURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        return try JSONDecoder().decode([BackgroundMediaDownloadJobMetadata].self, from: data)
    }

    private func persistJobs() throws {
        let url = try metadataURL()
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [
                .protectionKey: FileProtectionType.completeUntilFirstUserAuthentication,
            ]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var protectedDirectory = directory
        try? protectedDirectory.setResourceValues(values)

        let orderedJobs = jobs.values.sorted { $0.createdAt < $1.createdAt }
        let data = try JSONEncoder().encode(orderedJobs)
        try data.write(to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
        var protectedFile = url
        try? protectedFile.setResourceValues(values)
    }
}

private final class BackgroundMediaURLSessionDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let operationQueue: OperationQueue
    private weak var owner: BackgroundMediaTransferSession?
    private let lock = NSLock()
    private var downloadedData: [Int: Result<Data, BackgroundMediaTransferError>] = [:]
    private var pendingActorCallbacks = 0
    private var receivedFinishEvents = false

    init(owner: BackgroundMediaTransferSession) {
        self.owner = owner
        let queue = OperationQueue()
        queue.name = "com.toj.media.background-session-delegate"
        queue.maxConcurrentOperationCount = 1
        queue.qualityOfService = .utility
        self.operationQueue = queue
        super.init()
    }

    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        let result: Result<Data, BackgroundMediaTransferError>
        do {
            let values = try location.resourceValues(forKeys: [.fileSizeKey])
            guard
                let fileSize = values.fileSize,
                fileSize > 0,
                fileSize <= BackgroundMediaChunkValidator.maximumChunkBytes
            else { throw BackgroundMediaTransferError.unreadableDownload }
            result = .success(try Data(contentsOf: location, options: .mappedIfSafe))
        } catch {
            result = .failure(.unreadableDownload)
        }
        lock.lock()
        downloadedData[downloadTask.taskIdentifier] = result
        lock.unlock()
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: (any Error)?
    ) {
        lock.lock()
        let result = downloadedData.removeValue(forKey: task.taskIdentifier)
        pendingActorCallbacks += 1
        lock.unlock()

        let response = task.response as? HTTPURLResponse
        let request = task.currentRequest ?? task.originalRequest
        let requestedOffset = request?.url
            .flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
            .queryItems?
            .first(where: { $0.name == "offset" })?
            .value
            .flatMap(Int64.init)
        let data: Data?
        switch result {
        case let .success(value): data = value
        case .failure, .none: data = nil
        }
        let transportCode = error.map { ($0 as NSError).code }
        let completion = BackgroundMediaTransferSession.DownloadCompletion(
            jobId: task.taskDescription,
            requestedOffset: requestedOffset,
            data: data,
            statusCode: response?.statusCode,
            nextOffsetHeader: response?.value(forHTTPHeaderField: "X-Media-Next-Offset"),
            totalSizeHeader: response?.value(forHTTPHeaderField: "X-Media-Total-Size"),
            authorizationHeader: request?.value(forHTTPHeaderField: "Authorization"),
            transportErrorCode: transportCode
        )
        Task { [weak self, weak owner] in
            await owner?.receive(completion)
            self?.finishedActorCallback()
        }
    }

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest: URLRequest,
        completionHandler: @escaping (URLRequest?) -> Void
    ) {
        // Media endpoints are not expected to redirect. Rejecting redirects also prevents a bearer
        // credential from ever being forwarded to a different origin.
        completionHandler(nil)
    }

    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        lock.lock()
        receivedFinishEvents = true
        let canFinish = pendingActorCallbacks == 0
        lock.unlock()
        if canFinish { notifyFinishedEvents() }
    }

    private func finishedActorCallback() {
        lock.lock()
        pendingActorCallbacks = max(0, pendingActorCallbacks - 1)
        let canFinish = receivedFinishEvents && pendingActorCallbacks == 0
        lock.unlock()
        if canFinish { notifyFinishedEvents() }
    }

    private func notifyFinishedEvents() {
        lock.lock()
        receivedFinishEvents = false
        lock.unlock()
        guard let owner else { return }
        Task { await owner.finishedDeliveringBackgroundEvents() }
    }
}
