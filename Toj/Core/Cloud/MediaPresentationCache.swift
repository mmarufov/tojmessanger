import Foundation
import UIKit

nonisolated enum MediaPresentationVariant: String, CaseIterable, Sendable {
    case bubble720 = "bubble-720"
    case screen2048 = "screen-2048"
    case videoPoster = "video-poster"

    var maximumPixelSize: Int {
        switch self {
        case .bubble720, .videoPoster: 720
        case .screen2048: 2_048
        }
    }
}

nonisolated enum MediaAvailability: Equatable, Sendable {
    case decoded
    case localRepresentation
    case localComplete
    case partial(progress: Double)
    case remote
    case failed
}

nonisolated struct MediaPresentationKey: Hashable, Sendable {
    let mediaId: String
    let variant: MediaPresentationVariant
}

/// Process-wide decoded-image tier. Encrypted representations remain durable on disk; this cache
/// removes repeat decrypt/decode work while bubbles, viewers, and autoplay refer to the same media.
@MainActor
final class MediaPresentationCache {
    static let shared = MediaPresentationCache()

    private final class Entry: NSObject {
        let image: UIImage
        init(image: UIImage) { self.image = image }
    }

    private let images = NSCache<NSString, Entry>()
    private var inFlight: [
        MediaPresentationKey: (id: UUID, task: Task<SafeDecodedImage?, Never>)
    ] = [:]
    private var preparedVideoAssets: [
        String: (id: UUID, asset: StreamingMediaAsset, expiresAt: Date)
    ] = [:]
    private var preparedVideoExpiryTasks: [String: Task<Void, Never>] = [:]

    private init() {
        images.totalCostLimit = 64 * 1_024 * 1_024
    }

    func contains(_ key: MediaPresentationKey) -> Bool {
        images.object(forKey: cacheKey(key)) != nil
    }

    func image(
        for key: MediaPresentationKey,
        producer: @escaping @Sendable () async -> SafeDecodedImage?
    ) async -> UIImage? {
        let stringKey = cacheKey(key)
        if let entry = images.object(forKey: stringKey) { return entry.image }
        if let existing = inFlight[key] { return await existing.task.value?.image }

        let taskID = UUID()
        let task = Task { await producer() }
        inFlight[key] = (taskID, task)
        let decoded = await task.value
        if inFlight[key]?.id == taskID { inFlight[key] = nil }
        guard let decoded else { return nil }
        let cost = decoded.image.cgImage.map { $0.bytesPerRow * $0.height }
            ?? max(1, decoded.pixelWidth * decoded.pixelHeight * 4)
        images.setObject(Entry(image: decoded.image), forKey: stringKey, cost: cost)
        return decoded.image
    }

    func invalidate(mediaIds: Set<String>) {
        guard !mediaIds.isEmpty else { return }
        for key in Array(inFlight.keys) where mediaIds.contains(key.mediaId) {
            inFlight.removeValue(forKey: key)?.task.cancel()
        }
        for mediaId in mediaIds {
            preparedVideoExpiryTasks.removeValue(forKey: mediaId)?.cancel()
            preparedVideoAssets.removeValue(forKey: mediaId)
        }
        // NSCache cannot enumerate keys, so remove each supported representation deterministically.
        for mediaId in mediaIds {
            for variant in MediaPresentationVariant.allCases {
                images.removeObject(forKey: cacheKey(MediaPresentationKey(mediaId: mediaId, variant: variant)))
            }
        }
    }

    func removeAll() {
        inFlight.values.forEach { $0.task.cancel() }
        inFlight.removeAll()
        preparedVideoExpiryTasks.values.forEach { $0.cancel() }
        preparedVideoExpiryTasks.removeAll()
        preparedVideoAssets.removeAll()
        images.removeAllObjects()
    }

    /// Keeps only the lightweight AVURLAsset/resource-loader descriptor warm. Encrypted video
    /// bytes remain in the durable cache; the descriptor expires quickly and is handed off once.
    func storePreparedVideoAsset(
        _ asset: StreamingMediaAsset,
        mediaId: String,
        lifetime: TimeInterval = 15
    ) {
        preparedVideoExpiryTasks.removeValue(forKey: mediaId)?.cancel()
        let id = UUID()
        let expiresAt = Date(timeIntervalSinceNow: max(0, lifetime))
        preparedVideoAssets[mediaId] = (id, asset, expiresAt)
        preparedVideoExpiryTasks[mediaId] = Task { [weak self] in
            guard lifetime > 0 else {
                self?.removePreparedVideoAsset(mediaId: mediaId, id: id)
                return
            }
            try? await Task.sleep(for: .seconds(lifetime))
            guard !Task.isCancelled else { return }
            self?.removePreparedVideoAsset(mediaId: mediaId, id: id)
        }
    }

    func takePreparedVideoAsset(mediaId: String) -> StreamingMediaAsset? {
        guard let entry = preparedVideoAssets[mediaId] else { return nil }
        guard entry.expiresAt > Date() else {
            removePreparedVideoAsset(mediaId: mediaId, id: entry.id)
            return nil
        }
        preparedVideoExpiryTasks.removeValue(forKey: mediaId)?.cancel()
        preparedVideoAssets.removeValue(forKey: mediaId)
        entry.asset.activateAccess()
        return entry.asset
    }

    func hasPreparedVideoAsset(mediaId: String) -> Bool {
        guard let entry = preparedVideoAssets[mediaId] else { return false }
        guard entry.expiresAt > Date() else {
            removePreparedVideoAsset(mediaId: mediaId, id: entry.id)
            return false
        }
        return true
    }

    private func removePreparedVideoAsset(mediaId: String, id: UUID) {
        guard preparedVideoAssets[mediaId]?.id == id else { return }
        preparedVideoAssets.removeValue(forKey: mediaId)
        preparedVideoExpiryTasks.removeValue(forKey: mediaId)?.cancel()
    }

    private func cacheKey(_ key: MediaPresentationKey) -> NSString {
        "\(key.mediaId)|\(key.variant.rawValue)" as NSString
    }
}
