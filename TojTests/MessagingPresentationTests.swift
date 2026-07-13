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
            ConversationViewState(phase: .content, connection: .connected, unreadBelow: 0),
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
