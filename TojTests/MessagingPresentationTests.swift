import XCTest
import ImageIO
import UIKit
import UniformTypeIdentifiers
@testable import Toj

final class MessagingPresentationTests: XCTestCase {
    func testCapabilitySetsKeepProductionTruthful() {
        XCTAssertTrue(MessagingCapabilities.productionText.contains(.replies))
        XCTAssertTrue(MessagingCapabilities.productionText.contains(.editing))
        XCTAssertTrue(MessagingCapabilities.productionText.contains(.deletion))
        XCTAssertTrue(MessagingCapabilities.productionText.contains(.reactions))
        XCTAssertTrue(MessagingCapabilities.productionText.contains(.forwarding))
        XCTAssertFalse(MessagingCapabilities.productionText.contains(.media))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.media))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.voiceNotes))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.multipartMedia))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.groups))
        XCTAssertTrue(MessagingCapabilities.demo.contains(.calls))
    }

    func testMediaBubbleGeometryPreservesNormalRatiosAndBoundsExtremes() {
        XCTAssertEqual(MediaBubbleLayout.size(width: 1_000, height: 1_000), CGSize(width: 268, height: 268))
        XCTAssertEqual(MediaBubbleLayout.size(width: 1_600, height: 900).width, 268)
        XCTAssertLessThan(MediaBubbleLayout.size(width: 1_600, height: 900).height, 268)
        XCTAssertEqual(MediaBubbleLayout.size(width: 10_000, height: 300).height, 116)
        XCTAssertEqual(MediaBubbleLayout.size(width: 300, height: 10_000).height, 300)
        XCTAssertEqual(MediaBubbleLayout.size(width: 1_000, height: 1_600).width, 187.5)
    }

    func testVoiceGestureStateMachineUsesTelegramThresholds() {
        XCTAssertEqual(VoiceGestureIntent.resolve(translation: .zero), .recording)
        XCTAssertEqual(VoiceGestureIntent.resolve(translation: CGSize(width: -90, height: -20)), .cancel)
        XCTAssertEqual(VoiceGestureIntent.resolve(translation: CGSize(width: -10, height: -80)), .lock)
        XCTAssertEqual(
            VoiceGestureIntent.resolve(translation: CGSize(width: -100, height: -100)),
            .cancel,
            "Cancel wins when both thresholds are crossed"
        )
    }

    func testDeletedAndPendingDeleteMessagesNeverRenderInTimeline() {
        XCTAssertFalse(CloudAppModel.shouldDisplayInTimeline(
            messageState: "deleted_for_all",
            pendingMutationOperation: nil
        ))
        XCTAssertFalse(CloudAppModel.shouldDisplayInTimeline(
            messageState: "visible",
            pendingMutationOperation: "delete"
        ))
        XCTAssertTrue(CloudAppModel.shouldDisplayInTimeline(
            messageState: "visible",
            pendingMutationOperation: "edit"
        ))
    }

    func testFirstCachedTimelinePopulationIsTreatedAsAnAppend() {
        XCTAssertFalse(TimelineScrollBehavior.addedMessagesWereAppended(oldIDs: [], newIDs: []))
        XCTAssertTrue(TimelineScrollBehavior.addedMessagesWereAppended(
            oldIDs: [],
            newIDs: ["message-1", "message-2"]
        ))
        XCTAssertTrue(TimelineScrollBehavior.addedMessagesWereAppended(
            oldIDs: ["message-1"],
            newIDs: ["message-1", "message-2"]
        ))
        XCTAssertFalse(TimelineScrollBehavior.addedMessagesWereAppended(
            oldIDs: ["message-2"],
            newIDs: ["message-1", "message-2"]
        ))
    }

    func testReplicaSyncStatesExposeBoundedRetryablePresentation() {
        XCTAssertEqual(CloudAppModel.foregroundSyncTimeoutSeconds, 15)
        XCTAssertEqual(ReplicaSyncState.checking.title, "Checking connection…")
        XCTAssertEqual(ReplicaSyncState.updating.title, "Updating chats…")
        XCTAssertTrue(ReplicaSyncState.checking.showsProgress)
        XCTAssertTrue(ReplicaSyncState.updating.showsProgress)
        XCTAssertFalse(ReplicaSyncState.ready.showsRetry)
        XCTAssertTrue(ReplicaSyncState.offline.showsRetry)
    }

    func testReplicaFailuresKeepConnectivitySeparateFromProtocolAndStorageFailures() {
        let reachable = ReplicaNetworkSnapshot(
            networkClass: .wifi,
            isExpensive: false,
            isConstrained: false,
            isRoaming: false
        )
        let offline = ReplicaNetworkSnapshot(
            networkClass: .offline,
            isExpensive: false,
            isConstrained: false,
            isRoaming: false
        )

        XCTAssertEqual(
            CloudAppModel.replicaFailureState(for: URLError(.notConnectedToInternet), network: reachable),
            .offline
        )
        XCTAssertEqual(
            CloudAppModel.replicaFailureState(for: URLError(.timedOut), network: reachable),
            .connectionSlow
        )
        XCTAssertEqual(
            CloudAppModel.replicaFailureState(
                for: CloudAPIError(status: 503, message: "unavailable", retryAfter: nil),
                network: reachable
            ),
            .serverUnavailable
        )
        XCTAssertEqual(
            CloudAppModel.replicaFailureState(
                for: CloudAPIError(status: 401, message: "expired", retryAfter: nil),
                network: reachable
            ),
            .sessionExpired
        )
        XCTAssertEqual(
            CloudAppModel.replicaFailureState(
                for: DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "bad")),
                network: reachable
            ),
            .protocolFailure
        )
        XCTAssertEqual(
            CloudAppModel.replicaFailureState(for: CocoaError(.fileReadCorruptFile), network: reachable),
            .localFailure
        )
        XCTAssertEqual(
            CloudAppModel.replicaFailureState(
                for: CloudAPIError(status: 503, message: "unavailable", retryAfter: nil),
                network: offline
            ),
            .offline
        )
    }

    func testDifferencePageBudgetsFollowTheCurrentNetworkClass() {
        func snapshot(_ networkClass: ReplicaNetworkClass) -> ReplicaNetworkSnapshot {
            ReplicaNetworkSnapshot(
                networkClass: networkClass,
                isExpensive: networkClass != .wifi,
                isConstrained: networkClass == .constrained,
                isRoaming: networkClass == .roaming
            )
        }

        let wifi = CloudAppModel.differenceRequestLimits(for: snapshot(.wifi))
        XCTAssertEqual(wifi.maxEvents, 200)
        XCTAssertEqual(wifi.maxBytes, 256 * 1_024)
        let cellular = CloudAppModel.differenceRequestLimits(for: snapshot(.cellular))
        XCTAssertEqual(cellular.maxEvents, 100)
        XCTAssertEqual(cellular.maxBytes, 128 * 1_024)
        for networkClass in [
            ReplicaNetworkClass.unknown, .offline, .constrained, .roaming,
        ] {
            let bounded = CloudAppModel.differenceRequestLimits(for: snapshot(networkClass))
            XCTAssertEqual(bounded.maxEvents, 50)
            XCTAssertEqual(bounded.maxBytes, 64 * 1_024)
        }
    }

    func testPhysicalDeviceLoopbackRequiresAnExplicitDebugOverride() throws {
        let config = CloudConfig(baseURL: try XCTUnwrap(URL(string: "http://127.0.0.1:8788")))
        XCTAssertEqual(config.validationIssue(environment: [:]), .loopbackOnPhysicalDevice)
        XCTAssertNil(config.validationIssue(environment: ["SIMULATOR_UDID": "simulator"]))
        XCTAssertNil(config.validationIssue(environment: ["TOJ_ALLOW_LOOPBACK": "1"]))
        let productionLike = CloudConfig(
            baseURL: try XCTUnwrap(URL(string: "https://cloud.toj.example"))
        )
        XCTAssertNil(productionLike.validationIssue(environment: [:]))
    }

    func testReplicaSyncCoordinatorReplacesStaleWorkAndCoalescesRetryTaps() async throws {
        let probe = ReplicaCoordinatorProbe()
        let holder = ReplicaCoordinatorHolder()
        let coordinator = ReplicaSyncCoordinator { generation in
            await probe.start(generation)
            try? await Task.sleep(for: .milliseconds(30))
            if await holder.isCurrent(generation) {
                await probe.publish(generation)
            }
        }
        await holder.install(coordinator)

        await coordinator.trigger(.foreground)
        try await Task.sleep(for: .milliseconds(5))
        await coordinator.trigger(.manualRetry)
        await coordinator.trigger(.manualRetry)
        await coordinator.waitUntilIdle()

        let started = await probe.started
        let published = await probe.published
        XCTAssertEqual(started, [1, 2])
        XCTAssertEqual(published, [2])
    }

    func testReplicaSyncCoordinatorCoalescesHintsIntoOneFollowUpPass() async throws {
        let probe = ReplicaCoordinatorProbe()
        let coordinator = ReplicaSyncCoordinator { generation in
            await probe.start(generation)
            try? await Task.sleep(for: .milliseconds(20))
            await probe.publish(generation)
        }

        await coordinator.trigger(.foreground)
        try await Task.sleep(for: .milliseconds(2))
        await coordinator.trigger(.hint)
        await coordinator.trigger(.socketReconnect)
        await coordinator.trigger(.push)
        await coordinator.waitUntilIdle()

        let started = await probe.started
        XCTAssertEqual(started, [1, 2])
    }

    func testReplicaProbeDeadlineDoesNotWaitForCancellationInsensitiveWork() async {
        let startedAt = Date()
        let result = await ReplicaDeadline.run(for: .milliseconds(10)) {
            await withCheckedContinuation { continuation in
                DispatchQueue.global().asyncAfter(deadline: .now() + 0.15) {
                    continuation.resume(returning: 7)
                }
            }
        }
        let elapsed = Date().timeIntervalSince(startedAt)

        if case .timedOut = result {
            // Expected.
        } else {
            XCTFail("The initial probe should time out independently of the old operation")
        }
        XCTAssertLessThan(elapsed, 0.1)
    }

    func testMediaPrefetchSchedulerDrainsMoreThanSixJobsAndUsesWifiConcurrency() async {
        let probe = MediaPrefetchProbe(remaining: 17)
        let scheduler = MediaPrefetchScheduler { lane in await probe.perform(lane) }

        await scheduler.update(networkClass: .wifi, foregrounded: true)
        await scheduler.waitUntilIdle()

        let processed = await probe.processed
        let maximumConcurrent = await probe.maximumConcurrent
        let lanes = await probe.laneCounts
        XCTAssertEqual(processed, 17)
        XCTAssertEqual(maximumConcurrent, 3)
        XCTAssertGreaterThan(lanes[.fullMedia, default: 0], 0)
        XCTAssertGreaterThan(lanes[.thumbnail, default: 0], 0)
    }

    func testMediaPrefetchSchedulerWaitsOfflineAndResumesOnRecovery() async throws {
        let probe = MediaPrefetchProbe(remaining: 4)
        let scheduler = MediaPrefetchScheduler { lane in await probe.perform(lane) }

        await scheduler.update(networkClass: .offline, foregrounded: true)
        await scheduler.wake()
        try await Task.sleep(for: .milliseconds(20))
        let offlineProcessed = await probe.processed
        XCTAssertEqual(offlineProcessed, 0)

        await scheduler.update(networkClass: .cellular, foregrounded: true)
        await scheduler.waitUntilIdle()
        let recoveredProcessed = await probe.processed
        let maximumConcurrent = await probe.maximumConcurrent
        XCTAssertEqual(recoveredProcessed, 4)
        XCTAssertLessThanOrEqual(maximumConcurrent, 2)
    }

    @MainActor
    func testDecodedMediaRequestsCoalesceAndRemainMemoryCached() async throws {
        let cache = MediaPresentationCache.shared
        cache.removeAll()
        defer { cache.removeAll() }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 24, height: 16), format: format
        ).image { context in
            UIColor.systemIndigo.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 24, height: 16))
        }
        let decoded = SafeDecodedImage(image: image, pixelWidth: 24, pixelHeight: 16)
        let producer = DecodedMediaProducer(decoded: decoded)
        let key = MediaPresentationKey(mediaId: UUID().uuidString, variant: .bubble720)

        async let first = cache.image(for: key) { await producer.produce() }
        async let second = cache.image(for: key) { await producer.produce() }
        let images = await (first, second)

        XCTAssertNotNil(images.0)
        XCTAssertNotNil(images.1)
        let coalescedCount = await producer.count
        XCTAssertEqual(coalescedCount, 1)
        let cachedImage = await cache.image(for: key) { await producer.produce() }
        let cachedCount = await producer.count
        XCTAssertNotNil(cachedImage)
        XCTAssertEqual(cachedCount, 1)
    }

    @MainActor
    func testPreparedVideoDescriptorIsReusedOnceAndClearedWithItsMedia() {
        let cache = MediaPresentationCache.shared
        cache.removeAll()
        defer { cache.removeAll() }
        let engine = CloudMediaTransferEngine(
            config: CloudConfig(baseURL: URL(string: "https://media.invalid")!)
        )
        let media = CloudMedia(
            id: UUID().uuidString,
            kind: "video",
            contentType: "video/mp4",
            fileName: "cached.mp4",
            byteSize: 1_024,
            durationMs: 1_000,
            width: 320,
            height: 180,
            hasThumbnail: true
        )
        let prepared = engine.makeStreamingAsset(
            media: media,
            token: "test-token",
            startsAccessImmediately: false
        )

        cache.storePreparedVideoAsset(prepared, mediaId: media.id)
        XCTAssertTrue(cache.hasPreparedVideoAsset(mediaId: media.id))
        XCTAssertTrue(cache.takePreparedVideoAsset(mediaId: media.id) === prepared)
        XCTAssertFalse(cache.hasPreparedVideoAsset(mediaId: media.id))

        cache.storePreparedVideoAsset(prepared, mediaId: media.id)
        cache.invalidate(mediaIds: [media.id])
        XCTAssertFalse(cache.hasPreparedVideoAsset(mediaId: media.id))
    }

    @MainActor
    func testProductionChatOpensNewestEncryptedWindowAtBottom() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try CloudLocalStore(
            path: directory.appending(path: "cloud.sqlite").path,
            key: Data("latest-window-test-key".utf8)
        )
        let dialogId = "dialog-latest-window"
        let messages = (1...130).map { msgId in
            CloudMessage(
                dialogId: dialogId,
                msgId: Int64(msgId),
                senderAccountId: "peer-account",
                clientMsgId: "client-\(msgId)",
                kind: "text",
                text: "message \(msgId)",
                editVersion: 0,
                state: "visible",
                serverTs: String(format: "2026-07-18T00:%02d:%02dZ", (msgId / 60) % 60, msgId % 60)
            )
        }
        try await store.applyHistoryPage(HistoryPageResponse(
            dialogId: dialogId,
            messages: messages,
            nextBeforeMsgId: nil,
            hasMore: false
        ))
        let model = CloudAppModel(
            localStore: store,
            useDefaultLocalStore: false
        )

        await model.selectDialog(dialogId)

        XCTAssertEqual(model.openingTimelineAnchor, .bottom)
        XCTAssertEqual(model.lines.count, TimelineWindow.initialLimit)
        XCTAssertEqual(model.lines.first?.msgId, 11)
        XCTAssertEqual(model.lines.last?.msgId, 130)
        model.deselectDialog(dialogId)
    }

    func testVoiceRecorderCreatesProtectedDestinationBeforeAudioRecorderStarts() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "toj-voice-recorder-test-\(UUID().uuidString)", directoryHint: .isDirectory)
        let url = directory.appending(path: "voice.m4a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        try VoiceNoteRecorder.createProtectedRecordingFile(at: url)

        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.size] as? NSNumber, 0)
    }

    func testEveryMessageActionHasAccessibleCopyAndSymbol() {
        for action in MessageAction.allCases {
            XCTAssertFalse(action.title.isEmpty)
            XCTAssertFalse(action.systemImage.isEmpty)
        }
    }

    func testChatListPreviewKindMapsMessageMediaPrecisely() {
        XCTAssertEqual(ChatListPreviewKind(messageKind: "text"), .text)
        XCTAssertEqual(ChatListPreviewKind(messageKind: "photo"), .photo)
        XCTAssertEqual(ChatListPreviewKind(messageKind: "video"), .video)
        XCTAssertEqual(ChatListPreviewKind(messageKind: "voice"), .voice)
        XCTAssertEqual(ChatListPreviewKind(messageKind: "document"), .file)
        XCTAssertEqual(ChatListPreviewKind(messageKind: "unexpected"), .attachment)
        XCTAssertEqual(DemoAttachment.video(name: "Clip", duration: "0:08").chatListPreviewKind, .video)
        XCTAssertNil(ChatListPreviewKind.text.systemImage)
        XCTAssertFalse(ChatListPreviewKind.photo.title.isEmpty)
    }

    @MainActor
    func testSafeImageDecoderRejectsMalformedDataAndBoundsDecodedPixels() throws {
        XCTAssertNil(SafeMediaImageDecoder.decode(Data([0xff, 0xd8, 0xff]), maxPixelSize: 512))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 24), format: format).image { context in
            UIColor.systemBlue.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 32, height: 24))
        }
        let data = try XCTUnwrap(image.jpegData(compressionQuality: 0.8))
        let decoded = try XCTUnwrap(SafeMediaImageDecoder.decode(data, maxPixelSize: 16))
        XCTAssertEqual(decoded.pixelWidth, 32)
        XCTAssertEqual(decoded.pixelHeight, 24)
        XCTAssertLessThanOrEqual(decoded.image.size.width, 16)
        XCTAssertLessThanOrEqual(decoded.image.size.height, 16)
    }

    @MainActor
    func testPhotoUploadPreparationDecodesOnlyThumbnailSizedPixels() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 1_200, height: 900), format: format
        ).image { context in
            UIColor.systemPurple.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_200, height: 900))
        }
        let source = try XCTUnwrap(image.jpegData(compressionQuality: 0.9))

        let prepared = try XCTUnwrap(SafeMediaImageDecoder.preparePhotoUpload(source))
        let thumbnail = try XCTUnwrap(prepared.thumbnail)
        let decodedThumbnail = try XCTUnwrap(SafeMediaImageDecoder.decode(thumbnail, maxPixelSize: 1_024))

        XCTAssertEqual(prepared.pixelWidth, 1_200)
        XCTAssertEqual(prepared.pixelHeight, 900)
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        XCTAssertTrue(["jpg", "jpeg"].contains(prepared.filenameExtension))
        XCTAssertLessThanOrEqual(max(decodedThumbnail.pixelWidth, decodedThumbnail.pixelHeight), 640)
        XCTAssertLessThanOrEqual(thumbnail.count, 256 * 1024)
        XCTAssertFalse(prepared.data.isEmpty)
        XCTAssertEqual(
            CGImageSourceGetType(CGImageSourceCreateWithData(prepared.data as CFData, nil)!),
            UTType.jpeg.identifier as CFString
        )
    }

    @MainActor
    func testPhotoPreparationBoundsPixelsAndRemovesLocationMetadata() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(
            size: CGSize(width: 2_800, height: 140), format: format
        ).image { context in
            UIColor.systemGreen.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 2_800, height: 140))
        }
        let source = NSMutableData()
        let destination = try XCTUnwrap(CGImageDestinationCreateWithData(
            source, UTType.jpeg.identifier as CFString, 1, nil
        ))
        CGImageDestinationAddImage(destination, try XCTUnwrap(image.cgImage), [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: 38.5,
                kCGImagePropertyGPSLongitude: 68.8,
            ],
        ] as CFDictionary)
        XCTAssertTrue(CGImageDestinationFinalize(destination))

        let prepared = try XCTUnwrap(SafeMediaImageDecoder.preparePhotoUpload(source as Data))
        XCTAssertEqual(max(prepared.pixelWidth, prepared.pixelHeight), 2_560)
        XCTAssertEqual(prepared.contentType, "image/jpeg")
        let output = try XCTUnwrap(CGImageSourceCreateWithData(prepared.data as CFData, nil))
        let properties = try XCTUnwrap(
            CGImageSourceCopyPropertiesAtIndex(output, 0, nil) as? [CFString: Any]
        )
        XCTAssertNil(properties[kCGImagePropertyGPSDictionary])
    }

    func testMultipartPlanValidatesResumeStateAndOnlySchedulesMissingParts() throws {
        let plan = try XCTUnwrap(MediaMultipartPlan(
            byteSize: Int64(3 * 256 * 1024 - 17), partSize: 256 * 1024,
            totalParts: 3, receivedParts: [1]
        ))
        XCTAssertEqual(plan.missingParts, [0, 2])
        XCTAssertEqual(plan.range(for: 0, byteSize: Int64(3 * 256 * 1024 - 17)).count, 256 * 1024)
        XCTAssertEqual(plan.range(for: 2, byteSize: Int64(3 * 256 * 1024 - 17)).count, 256 * 1024 - 17)
        XCTAssertNil(MediaMultipartPlan(
            byteSize: 10, partSize: 256 * 1024, totalParts: 2, receivedParts: []
        ))
        XCTAssertNil(MediaMultipartPlan(
            byteSize: 600_000, partSize: 256 * 1024, totalParts: 3, receivedParts: [1, 1]
        ))
    }

    func testMediaPartSchedulerRunsExactlyThreeUploadsConcurrently() async throws {
        let probe = MediaSchedulerProbe()
        try await MediaPartScheduler.run(
            partIndexes: [0, 1, 2, 3, 4],
            upload: { partIndex in
                await probe.begin(partIndex)
                try await Task.sleep(for: .milliseconds(50))
                await probe.end(partIndex)
                return Int64(partIndex + 1)
            },
            didAcknowledge: { partIndex, bytes in
                await probe.acknowledge(partIndex, bytes: bytes)
            }
        )

        let maximumConcurrent = await probe.maximumConcurrent
        let uploaded = await probe.uploaded
        let acknowledged = await probe.acknowledged
        XCTAssertEqual(maximumConcurrent, 3)
        XCTAssertEqual(Set(uploaded), Set([0, 1, 2, 3, 4]))
        XCTAssertEqual(Set(acknowledged), Set([0, 1, 2, 3, 4]))
    }

    func testVideoContainerDetectionUsesActualBytes() {
        var mp4 = Data(repeating: 0, count: 12)
        mp4.replaceSubrange(4..<8, with: Data("ftyp".utf8))
        mp4.replaceSubrange(8..<12, with: Data("isom".utf8))
        XCTAssertEqual(
            SafeMediaVideoInspector.container(for: mp4),
            DetectedVideoContainer(contentType: "video/mp4", filenameExtension: "mp4")
        )

        var quickTime = mp4
        quickTime.replaceSubrange(8..<12, with: Data("qt  ".utf8))
        XCTAssertEqual(
            SafeMediaVideoInspector.container(for: quickTime),
            DetectedVideoContainer(contentType: "video/quicktime", filenameExtension: "mov")
        )
        var webM = Data([0x1a, 0x45, 0xdf, 0xa3])
        webM.append(Data(repeating: 0, count: 8))
        XCTAssertEqual(
            SafeMediaVideoInspector.container(for: webM),
            DetectedVideoContainer(contentType: "video/webm", filenameExtension: "webm")
        )
        XCTAssertNil(SafeMediaVideoInspector.container(for: Data("not video data".utf8)))
    }

    func testFileNamesAreSanitizedBeforeUpload() {
        XCTAssertEqual(SafeMediaFileMetadata.sanitizedFileName("folder/report.pdf"), "report.pdf")
        XCTAssertEqual(SafeMediaFileMetadata.sanitizedFileName("folder\\report.pdf"), "report.pdf")
        XCTAssertNil(SafeMediaFileMetadata.sanitizedFileName("bad\u{0000}name.pdf"))
        XCTAssertNil(SafeMediaFileMetadata.sanitizedFileName(String(repeating: "a", count: 256)))
        XCTAssertNil(SafeMediaFileMetadata.sanitizedFileName("   "))
    }

    func testPresentationStatesAreValueTypes() {
        XCTAssertEqual(
            ComposerViewState(mode: .text, text: "Hello", canSend: true),
            ComposerViewState(mode: .text, text: "Hello", canSend: true)
        )
        XCTAssertNotEqual(
            ConversationViewState(phase: .content, connection: .live, unreadBelow: 0),
            ConversationViewState(phase: .partial(message: "Offline"), connection: .offline, unreadBelow: 2)
        )
    }

    @MainActor
    func testDemoAndProductionExposeTheirRealCapabilities() async {
        let model = CloudAppModel(useDefaultLocalStore: false)
        XCTAssertEqual(model.capabilities, [.replies], "Unknown servers must fail closed")

        model.enterDemoMode()

        XCTAssertEqual(model.capabilities, .demo)
        await Task.yield()
    }

    @MainActor
    func testDemoSearchScopesMessagesAndAttachments() async {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()

        XCTAssertEqual(model.dialogs(matching: "Олично", scope: .messages).map(\.id), ["demo-mehrona"])
        XCTAssertEqual(model.dialogs(matching: "Шоми", scope: .media).map(\.id), ["demo-mehrona"])
        XCTAssertEqual(model.dialogs(matching: "Toj-Brief", scope: .files).map(\.id), ["demo-firooz"])
        XCTAssertTrue(model.dialogs(matching: "anything", scope: .links).isEmpty)
        XCTAssertEqual(model.dialogs(matching: "Документы", scope: .chats).map(\.id), ["demo-firooz"])
        XCTAssertTrue(model.dialogs(matching: "Документы", scope: .people).isEmpty)
    }

    @MainActor
    func testDraftPersistsPerConversationAndAppearsInChatRow() async {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()

        await model.selectDialog("demo-mehrona")
        model.draft = "Паёми нотамом"
        model.deselectDialog("demo-mehrona")

        XCTAssertEqual(model.dialogs.first(where: { $0.id == "demo-mehrona" })?.draftPreview, "Паёми нотамом")

        await model.selectDialog("demo-mehrona")
        XCTAssertEqual(model.draft, "Паёми нотамом")
    }

    @MainActor
    func testOpeningDemoConversationClearsUnreadWithoutDroppingOrganizationState() async {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()
        let before = model.dialogs.first(where: { $0.id == "demo-mehrona" })
        XCTAssertEqual(before?.isPinned, true)
        XCTAssertEqual(before?.mentionCount, 1)

        await model.selectDialog("demo-mehrona")

        let after = model.dialogs.first(where: { $0.id == "demo-mehrona" })
        XCTAssertEqual(after?.unreadCount, 0)
        XCTAssertEqual(after?.mentionCount, 0)
        XCTAssertEqual(after?.isPinned, true)
    }

    @MainActor
    func testReplyAndEditComposerModesAreDeterministic() async throws {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()
        await model.selectDialog("demo-mehrona")
        let incoming = try XCTUnwrap(model.lines.first(where: { !$0.mine }))
        let outgoing = try XCTUnwrap(model.lines.first(where: { $0.mine }))

        model.beginReply(to: incoming)
        XCTAssertEqual(model.composerMode, .replying(messageId: incoming.id, preview: incoming.text))

        model.beginEditing(outgoing)
        XCTAssertEqual(model.composerMode, .editing(messageId: outgoing.id, original: outgoing.text))
        XCTAssertEqual(model.draft, outgoing.text)

        model.cancelComposerMode()
        XCTAssertEqual(model.composerMode, .text)
        XCTAssertTrue(model.draft.isEmpty)
    }

    @MainActor
    func testDemoChatOrganizationStateChangesWithoutServerMutation() async {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()

        model.toggleMuted("demo-mehrona")
        model.togglePinned("demo-firooz")
        model.archive("demo-aziz")

        XCTAssertEqual(model.dialogs.first(where: { $0.id == "demo-mehrona" })?.isMuted, true)
        XCTAssertEqual(model.dialogs.first?.id, "demo-mehrona", "Existing pinned chat remains first")
        XCTAssertFalse(model.dialogs(matching: "", scope: .chats).contains(where: { $0.id == "demo-aziz" }))
        await Task.yield()
    }

    @MainActor
    func testDemoReactionAndDeletionUpdateTheActiveConversation() async throws {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()
        await model.selectDialog("demo-mehrona")
        let line = try XCTUnwrap(model.lines.first)

        model.reactToDemoMessage(line.id, reaction: "🔥")
        XCTAssertEqual(model.lines.first(where: { $0.id == line.id })?.reactions, ["🔥"])

        model.reactToDemoMessage(line.id, reaction: "🔥")
        XCTAssertEqual(model.lines.first(where: { $0.id == line.id })?.reactions, [])

        model.deleteDemoMessage(line.id)
        XCTAssertFalse(model.lines.contains(where: { $0.id == line.id }))
    }

    @MainActor
    func testDemoAttachmentAndVoiceNoteUsePresentationPayloads() async throws {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()
        await model.selectDialog("demo-firooz")

        model.sendDemoAttachment(.video(name: "Шом", duration: "0:24"), caption: "Нигар")
        let video = try XCTUnwrap(model.lines.last)
        XCTAssertEqual(video.text, "Нигар")
        XCTAssertEqual(video.attachment, .video(name: "Шом", duration: "0:24"))

        model.beginDemoRecording()
        XCTAssertEqual(model.composerMode, .recording(elapsedSeconds: 0))
        model.finishDemoRecording()
        XCTAssertEqual(model.lines.last?.attachment, .voice(duration: "0:08"))
        XCTAssertEqual(model.composerMode, .text)
    }

    @MainActor
    func testSendingAnEditUpdatesInsteadOfAppending() async throws {
        let model = CloudAppModel(useDefaultLocalStore: false)
        model.enterDemoMode()
        await model.selectDialog("demo-mehrona")
        let outgoing = try XCTUnwrap(model.lines.first(where: { $0.mine }))
        let originalCount = model.lines.count

        model.beginEditing(outgoing)
        model.draft = "Паёми таҳриршуда"
        await model.sendDraft()

        XCTAssertEqual(model.lines.count, originalCount)
        XCTAssertEqual(model.lines.first(where: { $0.id == outgoing.id })?.text, "Паёми таҳриршуда")
        XCTAssertEqual(model.lines.first(where: { $0.id == outgoing.id })?.isEdited, true)
        XCTAssertEqual(model.composerMode, .text)
    }

    func testTimelinePresentationIsPrecomputedWithStableGrouping() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(secondsFromGMT: 0))
        let now = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-07-16T12:00:00Z"))
        let result = TimelinePresentationBuilder.build(
            [
                TimelinePresentationInput(id: "1", mine: true, timestamp: "2026-07-15T20:00:00Z"),
                TimelinePresentationInput(id: "2", mine: true, timestamp: "2026-07-16T10:00:00Z"),
                TimelinePresentationInput(id: "3", mine: true, timestamp: "2026-07-16T10:03:00Z"),
                TimelinePresentationInput(id: "4", mine: false, timestamp: "2026-07-16T10:04:00Z"),
            ],
            now: now,
            calendar: calendar
        )

        XCTAssertEqual(result.map(\.id), ["1", "2", "3", "4"])
        XCTAssertEqual(result[0].dayLabel, "Yesterday")
        XCTAssertEqual(result[1].dayLabel, "Today")
        XCTAssertTrue(result[1].isFirstInGroup)
        XCTAssertFalse(result[1].isLastInGroup)
        XCTAssertFalse(result[2].isFirstInGroup)
        XCTAssertTrue(result[2].isLastInGroup)
        XCTAssertTrue(result[3].isFirstInGroup)
        XCTAssertNotNil(result[3].timestampLabel)
    }
}

private actor MediaSchedulerProbe {
    private var active = 0
    private(set) var maximumConcurrent = 0
    private(set) var uploaded: [Int] = []
    private(set) var acknowledged: [Int] = []

    func begin(_ partIndex: Int) {
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        uploaded.append(partIndex)
    }

    func end(_ partIndex: Int) {
        active -= 1
    }

    func acknowledge(_ partIndex: Int, bytes: Int64) {
        guard bytes == Int64(partIndex + 1) else { return }
        acknowledged.append(partIndex)
    }
}

private actor MediaPrefetchProbe {
    private var remaining: Int
    private var active = 0
    private(set) var processed = 0
    private(set) var maximumConcurrent = 0
    private(set) var laneCounts: [MediaPrefetchLane: Int] = [:]

    init(remaining: Int) {
        self.remaining = remaining
    }

    func perform(_ lane: MediaPrefetchLane) async -> Bool {
        guard remaining > 0 else { return false }
        remaining -= 1
        processed += 1
        laneCounts[lane, default: 0] += 1
        active += 1
        maximumConcurrent = max(maximumConcurrent, active)
        try? await Task.sleep(for: .milliseconds(5))
        active -= 1
        return true
    }
}

private actor DecodedMediaProducer {
    private let decoded: SafeDecodedImage
    private(set) var count = 0

    init(decoded: SafeDecodedImage) {
        self.decoded = decoded
    }

    func produce() async -> SafeDecodedImage? {
        count += 1
        try? await Task.sleep(for: .milliseconds(20))
        return decoded
    }
}

private actor ReplicaCoordinatorProbe {
    private(set) var started: [UInt64] = []
    private(set) var published: [UInt64] = []

    func start(_ generation: UInt64) {
        started.append(generation)
    }

    func publish(_ generation: UInt64) {
        published.append(generation)
    }
}

private actor ReplicaCoordinatorHolder {
    private var coordinator: ReplicaSyncCoordinator?

    func install(_ coordinator: ReplicaSyncCoordinator) {
        self.coordinator = coordinator
    }

    func isCurrent(_ generation: UInt64) async -> Bool {
        guard let coordinator else { return false }
        return await coordinator.isCurrent(generation)
    }
}
