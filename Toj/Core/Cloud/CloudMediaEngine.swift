import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit

struct SafeDecodedImage {
    let image: UIImage
    let pixelWidth: Int
    let pixelHeight: Int
}

enum SafeMediaImageDecoder {
    private static let maxDimension = 8_192
    private static let maxPixels = 40_000_000

    static func decode(_ data: Data, maxPixelSize: Int) -> SafeDecodedImage? {
        guard !data.isEmpty, maxPixelSize > 0,
              let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
              ),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue,
              let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue,
              width > 0, height > 0, width <= maxDimension, height <= maxDimension,
              Int64(width) * Int64(height) <= Int64(maxPixels)
        else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: min(maxPixelSize, maxDimension),
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return SafeDecodedImage(image: UIImage(cgImage: cgImage), pixelWidth: width, pixelHeight: height)
    }
}

nonisolated struct CloudMedia: Codable, Equatable, Sendable, Identifiable {
    let id: String
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let hasThumbnail: Bool

    enum CodingKeys: String, CodingKey {
        case id, kind
        case contentType = "content_type"
        case fileName = "file_name"
        case byteSize = "byte_size"
        case durationMs = "duration_ms"
        case width, height
        case hasThumbnail = "has_thumbnail"
    }

    var displayName: String {
        if let fileName { return fileName }
        switch kind {
        case "photo": return String(localized: "Photo")
        case "video": return String(localized: "Video")
        case "voice": return String(localized: "Voice message")
        default: return String(localized: "File")
        }
    }

    var formattedSize: String {
        ByteCountFormatter.string(fromByteCount: byteSize, countStyle: .file)
    }

    var formattedDuration: String? {
        guard let durationMs else { return nil }
        let seconds = max(0, durationMs / 1_000)
        return String(format: "%lld:%02lld", seconds / 60, seconds % 60)
    }
}

nonisolated struct MediaUploadCreation: Codable, Sendable {
    nonisolated struct Quota: Codable, Sendable {
        let usedBytes: Int64
        let limitBytes: Int64
    }

    let mediaId: String
    let uploadOffset: Int64
    let chunkSize: Int
    let expiresAt: String
    let quota: Quota
}

nonisolated struct MediaUploadState: Codable, Sendable {
    let mediaId: String
    let uploadOffset: Int64
    let byteSize: Int64
    let status: String
    let expiresAt: String
    let chunkSize: Int
}

nonisolated struct MediaChunkResponse: Codable, Sendable {
    let mediaId: String
    let uploadOffset: Int64
    let complete: Bool
    let duplicate: Bool
}

nonisolated struct MediaCompleteResponse: Codable, Sendable {
    let mediaId: String
    let ready: Bool
    let duplicate: Bool
}

nonisolated struct MediaUploadRequest: Codable, Sendable {
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let sha256: String
    let durationMs: Int64?
    let width: Int?
    let height: Int?
}

nonisolated struct PreparedMediaUpload: Sendable {
    let transferId: String
    let kind: String
    let contentType: String
    let fileName: String?
    let byteSize: Int64
    let sha256: String
    let durationMs: Int64?
    let width: Int?
    let height: Int?
    let encryptedSourcePath: String
    let encryptedThumbnailPath: String?
}

struct CloudMediaAPI: Sendable {
    let config: CloudConfig
    var session: URLSession = .shared

    func createUpload(_ requestBody: MediaUploadRequest, token: String) async throws -> MediaUploadCreation {
        try await jsonRequest(path: "v1/media/uploads", method: "POST", body: requestBody, token: token)
    }

    func uploadState(mediaId: String, token: String) async throws -> MediaUploadState {
        try await jsonRequest(path: "v1/media/uploads/\(mediaId)", method: "GET", body: Optional<String>.none, token: token)
    }

    func uploadChunk(mediaId: String, offset: Int64, bytes: Data, token: String) async throws -> MediaChunkResponse {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)/chunks"))
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue(String(offset), forHTTPHeaderField: "Upload-Offset")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await runJSON(request)
    }

    func uploadThumbnail(mediaId: String, bytes: Data, token: String) async throws {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)/thumbnail"))
        request.httpMethod = "PUT"
        request.httpBody = bytes
        request.setValue("image/jpeg", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: MediaThumbnailResponse = try await runJSON(request)
    }

    func completeUpload(mediaId: String, token: String) async throws -> MediaCompleteResponse {
        try await jsonRequest(
            path: "v1/media/uploads/\(mediaId)/complete", method: "POST",
            body: EmptyMediaBody(), token: token
        )
    }

    func cancelUpload(mediaId: String, token: String) async throws {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)"))
        request.httpMethod = "DELETE"
        request.timeoutInterval = 5
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let _: MediaCancelResponse = try await runJSON(request)
    }

    func downloadChunk(mediaId: String, offset: Int64, token: String) async throws -> MediaDownloadChunk {
        var components = URLComponents(url: config.httpURL(path: "v1/media/\(mediaId)/chunks"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "offset", value: String(offset))]
        var request = URLRequest(url: components.url!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        let http = try validate(data: data, response: response)
        guard
            let next = http.value(forHTTPHeaderField: "X-Media-Next-Offset").flatMap(Int64.init),
            let total = http.value(forHTTPHeaderField: "X-Media-Total-Size").flatMap(Int64.init)
        else { throw CloudAPIError(status: -1, message: "Invalid media response", retryAfter: nil) }
        guard
            !data.isEmpty, data.count <= 1024 * 1024,
            total > 0, total <= 25 * 1024 * 1024,
            next == offset + Int64(data.count), next <= total
        else { throw CloudAPIError(status: -1, message: "Invalid media response", retryAfter: nil) }
        return MediaDownloadChunk(data: data, nextOffset: next, totalSize: total)
    }

    func downloadThumbnail(mediaId: String, token: String) async throws -> Data {
        var request = URLRequest(url: config.httpURL(path: "v1/media/\(mediaId)/thumbnail"))
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        _ = try validate(data: data, response: response)
        guard !data.isEmpty, data.count <= 256 * 1024 else {
            throw CloudAPIError(status: -1, message: "Invalid media preview", retryAfter: nil)
        }
        return data
    }

    private func jsonRequest<Body: Encodable, Response: Decodable>(
        path: String, method: String, body: Body?, token: String
    ) async throws -> Response {
        var request = URLRequest(url: config.httpURL(path: path))
        request.httpMethod = method
        if let body {
            request.httpBody = try JSONEncoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        return try await runJSON(request)
    }

    private func runJSON<Response: Decodable>(_ request: URLRequest) async throws -> Response {
        let (data, response) = try await session.data(for: request)
        _ = try validate(data: data, response: response)
        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func validate(data: Data, response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else {
            throw CloudAPIError(status: -1, message: "Invalid server response", retryAfter: nil)
        }
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONDecoder().decode(MediaServerError.self, from: data).error)
                ?? "HTTP \(http.statusCode)"
            throw CloudAPIError(
                status: http.statusCode, message: message,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init)
            )
        }
        return http
    }
}

private struct EmptyMediaBody: Codable {}
private struct MediaThumbnailResponse: Codable { let mediaId: String; let uploaded: Bool }
private struct MediaCancelResponse: Codable { let mediaId: String; let cancelled: Bool }
private struct MediaServerError: Codable { let error: String }
nonisolated struct MediaDownloadChunk: Sendable { let data: Data; let nextOffset: Int64; let totalSize: Int64 }

actor EncryptedMediaCache {
    static let defaultLimitBytes: Int64 = 200 * 1024 * 1024

    private let root: URL
    private let previewRoot: URL
    private let key: SymmetricKey
    private let fileManager = FileManager.default
    private let limitBytes: Int64

    init(root: URL? = nil, keyData: Data? = nil, limitBytes: Int64 = defaultLimitBytes) throws {
        let base: URL
        if let root { base = root }
        else {
            let support = try fileManager.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true
            )
            base = support.appending(path: "Toj/media", directoryHint: .isDirectory)
        }
        self.root = base
        self.previewRoot = root == nil
            ? fileManager.temporaryDirectory.appending(path: "TojMediaPreviews", directoryHint: .isDirectory)
            : base.appending(path: "previews", directoryHint: .isDirectory)
        self.limitBytes = limitBytes
        let sourceKey = try keyData ?? LocalDatabaseKeyStore().loadOrCreateKey()
        var material = Data("toj/media-cache/v1".utf8)
        material.append(sourceKey)
        self.key = SymmetricKey(data: Data(SHA256.hash(data: material)))
        try fileManager.createDirectory(at: base, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: base.appending(path: "uploads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: base.appending(path: "downloads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: base.appending(path: "thumbnails"), withIntermediateDirectories: true)
        // Decrypted previews are unavoidable for AVPlayer and the system share sheet. Purge crash
        // leftovers at startup, keep them out of backups, and apply the strongest file protection.
        if fileManager.fileExists(atPath: previewRoot.path) { try fileManager.removeItem(at: previewRoot) }
        try fileManager.createDirectory(at: previewRoot, withIntermediateDirectories: true)
        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var protectedPreviewRoot = previewRoot
        try? protectedPreviewRoot.setResourceValues(resourceValues)
    }

    func prepareUpload(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) throws -> PreparedMediaUpload {
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw MediaCacheError.unsupportedSize }
        guard (thumbnail?.count ?? 0) <= 256 * 1024 else { throw MediaCacheError.thumbnailTooLarge }
        try ensureCapacity(additionalBytes: Int64(data.count + (thumbnail?.count ?? 0) + 128))
        let transferId = UUID().uuidString.lowercased()
        let source = root.appending(path: "uploads/\(transferId).tojmedia")
        do {
            try writeEncrypted(data, to: source, aad: "upload|\(transferId)")
            var thumbnailPath: String?
            if let thumbnail, !thumbnail.isEmpty {
                let url = root.appending(path: "uploads/\(transferId).thumb")
                try writeEncrypted(thumbnail, to: url, aad: "upload-thumb|\(transferId)")
                thumbnailPath = url.path
            }
            return PreparedMediaUpload(
                transferId: transferId, kind: kind, contentType: contentType,
                fileName: fileName, byteSize: Int64(data.count),
                sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined(),
                durationMs: durationMs, width: width, height: height,
                encryptedSourcePath: source.path, encryptedThumbnailPath: thumbnailPath
            )
        } catch {
            try? fileManager.removeItem(at: source)
            try? fileManager.removeItem(at: root.appending(path: "uploads/\(transferId).thumb"))
            throw error
        }
    }

    func uploadData(for transfer: MediaTransferRecord) throws -> Data {
        try readEncrypted(
            from: URL(filePath: transfer.encryptedSourcePath),
            aad: "upload|\(transfer.transferId)"
        )
    }

    func uploadThumbnail(for transfer: MediaTransferRecord) throws -> Data? {
        guard let path = transfer.encryptedThumbnailPath else { return nil }
        return try readEncrypted(from: URL(filePath: path), aad: "upload-thumb|\(transfer.transferId)")
    }

    func preparedData(transferId: String) throws -> Data {
        try readEncrypted(
            from: root.appending(path: "uploads/\(transferId).tojmedia"),
            aad: "upload|\(transferId)"
        )
    }

    func preparedThumbnail(transferId: String) throws -> Data? {
        let url = root.appending(path: "uploads/\(transferId).thumb")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try readEncrypted(from: url, aad: "upload-thumb|\(transferId)")
    }

    func finishUpload(_ transfer: MediaTransferRecord) throws {
        try? fileManager.removeItem(at: URL(filePath: transfer.encryptedSourcePath))
        if let path = transfer.encryptedThumbnailPath { try? fileManager.removeItem(at: URL(filePath: path)) }
    }

    func discardPrepared(_ prepared: PreparedMediaUpload) {
        try? fileManager.removeItem(at: URL(filePath: prepared.encryptedSourcePath))
        if let path = prepared.encryptedThumbnailPath {
            try? fileManager.removeItem(at: URL(filePath: path))
        }
    }

    func thumbnail(mediaId: String) throws -> Data? {
        let url = root.appending(path: "thumbnails/\(mediaId).tojthumb")
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        do {
            let data = try readEncrypted(from: url, aad: "thumbnail|\(mediaId)")
            try touch(url)
            return data
        } catch {
            // A partial write, disk corruption, or stale key must never permanently poison media.
            try? fileManager.removeItem(at: url)
            return nil
        }
    }

    func storeThumbnail(_ data: Data, mediaId: String) throws {
        try ensureCapacity(additionalBytes: Int64(data.count + 32))
        let url = root.appending(path: "thumbnails/\(mediaId).tojthumb")
        try writeEncrypted(data, to: url, aad: "thumbnail|\(mediaId)")
        try enforceQuota()
    }

    func contiguousDownloadOffset(mediaId: String) throws -> Int64 {
        let dir = downloadDirectory(mediaId)
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }
        do {
            let offsets = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .compactMap { Int64($0.deletingPathExtension().lastPathComponent) }
                .sorted()
            var expected: Int64 = 0
            for offset in offsets {
                guard offset == expected else { break }
                let data = try readEncrypted(
                    from: chunkURL(mediaId: mediaId, offset: offset),
                    aad: "download|\(mediaId)|\(offset)"
                )
                expected += Int64(data.count)
            }
            return expected
        } catch {
            // Restart a corrupt partial download from zero instead of failing forever.
            try? fileManager.removeItem(at: dir)
            return 0
        }
    }

    func storeDownloadChunk(_ data: Data, mediaId: String, offset: Int64) throws {
        try ensureCapacity(additionalBytes: Int64(data.count + 32))
        let dir = downloadDirectory(mediaId)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        try writeEncrypted(data, to: chunkURL(mediaId: mediaId, offset: offset), aad: "download|\(mediaId)|\(offset)")
        try touch(dir)
        try enforceQuota(excluding: dir)
    }

    func downloadedData(mediaId: String, expectedSize: Int64) throws -> Data? {
        guard try contiguousDownloadOffset(mediaId: mediaId) == expectedSize else { return nil }
        let dir = downloadDirectory(mediaId)
        do {
            let urls = try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
                .compactMap { url -> (Int64, URL)? in
                    guard let offset = Int64(url.deletingPathExtension().lastPathComponent) else { return nil }
                    return (offset, url)
                }.sorted { $0.0 < $1.0 }
            var result = Data(capacity: Int(expectedSize))
            for (offset, url) in urls {
                result.append(try readEncrypted(from: url, aad: "download|\(mediaId)|\(offset)"))
            }
            try touch(dir)
            return result
        } catch {
            try? fileManager.removeItem(at: dir)
            return nil
        }
    }

    func clearAll() throws {
        if fileManager.fileExists(atPath: root.path) { try fileManager.removeItem(at: root) }
        if fileManager.fileExists(atPath: previewRoot.path) { try fileManager.removeItem(at: previewRoot) }
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "uploads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "downloads"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: root.appending(path: "thumbnails"), withIntermediateDirectories: true)
        try fileManager.createDirectory(at: previewRoot, withIntermediateDirectories: true)
    }

    func clearDownloaded() throws {
        for name in ["downloads", "thumbnails"] {
            let url = root.appending(path: name, directoryHint: .isDirectory)
            if fileManager.fileExists(atPath: url.path) { try fileManager.removeItem(at: url) }
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
        if fileManager.fileExists(atPath: previewRoot.path) { try fileManager.removeItem(at: previewRoot) }
        try fileManager.createDirectory(at: previewRoot, withIntermediateDirectories: true)
    }

    func createTemporaryPreview(_ data: Data, fileExtension: String?) throws -> URL {
        guard !data.isEmpty, data.count <= 25 * 1024 * 1024 else { throw MediaCacheError.unsupportedSize }
        let candidate = (fileExtension ?? "").lowercased()
        let safeExtension = candidate.range(of: "^[a-z0-9]{1,10}$", options: .regularExpression) == nil
            ? "bin" : candidate
        let url = previewRoot.appending(path: "\(UUID().uuidString.lowercased()).\(safeExtension)")
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        return url
    }

    func removeTemporaryPreview(_ url: URL) {
        let parent = previewRoot.standardizedFileURL.path + "/"
        guard url.standardizedFileURL.path.hasPrefix(parent) else { return }
        try? fileManager.removeItem(at: url)
    }

    func downloadedUsageBytes() throws -> Int64 {
        try cachedEntries().reduce(0) { $0 + $1.size }
    }

    private func writeEncrypted(_ data: Data, to url: URL, aad: String) throws {
        let sealed = try AES.GCM.seal(data, using: key, authenticating: Data(aad.utf8))
        guard let combined = sealed.combined else { throw MediaCacheError.encryptionFailed }
        try combined.write(to: url, options: [.atomic, .completeFileProtection])
    }

    private func readEncrypted(from url: URL, aad: String) throws -> Data {
        let combined = try Data(contentsOf: url)
        let sealed = try AES.GCM.SealedBox(combined: combined)
        return try AES.GCM.open(sealed, using: key, authenticating: Data(aad.utf8))
    }

    private func downloadDirectory(_ mediaId: String) -> URL {
        root.appending(path: "downloads/\(mediaId)", directoryHint: .isDirectory)
    }

    private func chunkURL(mediaId: String, offset: Int64) -> URL {
        downloadDirectory(mediaId).appending(path: "\(offset).tojchunk")
    }

    private func touch(_ url: URL) throws {
        try fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
    }

    private func enforceQuota(excluding protectedURL: URL? = nil) throws {
        let candidates = try cachedEntries().sorted { $0.date < $1.date }
        var total = try totalCacheBytes()
        guard total > limitBytes else { return }
        for entry in candidates where entry.url != protectedURL {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            if total <= limitBytes { break }
        }
        if total > limitBytes { throw MediaCacheError.localQuotaExceeded }
    }

    private func ensureCapacity(additionalBytes: Int64) throws {
        var total = try totalCacheBytes()
        guard total + additionalBytes > limitBytes else { return }
        for entry in try cachedEntries().sorted(by: { $0.date < $1.date }) {
            try? fileManager.removeItem(at: entry.url)
            total -= entry.size
            if total + additionalBytes <= limitBytes { return }
        }
        throw MediaCacheError.localQuotaExceeded
    }

    private func totalCacheBytes() throws -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey]
        ) else { return 0 }
        return (enumerator.allObjects as? [URL] ?? []).reduce(0) { total, url in
            let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }

    private func cachedEntries() throws -> [(url: URL, size: Int64, date: Date)] {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
        let roots = [root.appending(path: "downloads"), root.appending(path: "thumbnails")]
        return try roots.flatMap { base -> [(URL, Int64, Date)] in
            guard fileManager.fileExists(atPath: base.path) else { return [] }
            return try fileManager.contentsOfDirectory(at: base, includingPropertiesForKeys: Array(keys)).map { url in
                let values = try url.resourceValues(forKeys: keys)
                let size: Int64
                if values.isDirectory == true {
                    let enumerator = fileManager.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey])
                    size = (enumerator?.allObjects as? [URL] ?? []).reduce(0) {
                        $0 + Int64((try? $1.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
                    }
                } else { size = Int64(values.fileSize ?? 0) }
                return (url, size, values.contentModificationDate ?? .distantPast)
            }
        }
    }
}

actor CloudMediaTransferEngine {
    private let api: CloudMediaAPI
    private let cache: EncryptedMediaCache?

    init(
        config: CloudConfig = .current,
        cache: EncryptedMediaCache? = nil,
        session: URLSession = .shared
    ) {
        self.api = CloudMediaAPI(config: config, session: session)
        self.cache = cache ?? (try? EncryptedMediaCache())
    }

    func prepare(
        data: Data, kind: String, contentType: String, fileName: String?,
        durationMs: Int64? = nil, width: Int? = nil, height: Int? = nil,
        thumbnail: Data? = nil
    ) async throws -> PreparedMediaUpload {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        return try await cache.prepareUpload(
            data: data, kind: kind, contentType: contentType, fileName: fileName,
            durationMs: durationMs, width: width, height: height, thumbnail: thumbnail
        )
    }

    func upload(
        transfer: MediaTransferRecord, token: String, localStore: CloudLocalStore,
        progress: @Sendable (Double) async -> Void
    ) async throws -> String {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        let data = try await cache.uploadData(for: transfer)
        var mediaId = transfer.mediaId
        var offset = transfer.uploadOffset
        var chunkSize = 256 * 1024
        if let existingId = mediaId {
            do {
                let remote = try await api.uploadState(mediaId: existingId, token: token)
                guard remote.status == "uploading" || remote.status == "ready" else { throw MediaCacheError.uploadExpired }
                guard
                    remote.mediaId == existingId, remote.byteSize == transfer.byteSize,
                    remote.uploadOffset >= 0, remote.uploadOffset <= transfer.byteSize,
                    remote.chunkSize > 0, remote.chunkSize <= 1024 * 1024,
                    remote.status != "ready" || remote.uploadOffset == transfer.byteSize
                else { throw MediaCacheError.invalidState }
                offset = remote.uploadOffset
                chunkSize = remote.chunkSize
                if remote.status == "ready" { return existingId }
            } catch let error as CloudAPIError where error.status == 404 || error.status == 410 {
                try await localStore.resetMediaUpload(transferId: transfer.transferId)
                mediaId = nil
                offset = 0
            }
        }
        if mediaId == nil {
            let created = try await api.createUpload(
                MediaUploadRequest(
                    kind: transfer.kind, contentType: transfer.contentType,
                    fileName: transfer.fileName, byteSize: transfer.byteSize,
                    sha256: transfer.sha256, durationMs: transfer.durationMs,
                    width: transfer.width, height: transfer.height
                ), token: token
            )
            guard
                UUID(uuidString: created.mediaId) != nil,
                created.uploadOffset >= 0, created.uploadOffset <= transfer.byteSize,
                created.chunkSize > 0, created.chunkSize <= 1024 * 1024
            else { throw MediaCacheError.invalidState }
            mediaId = created.mediaId
            offset = created.uploadOffset
            chunkSize = created.chunkSize
            try await localStore.updateMediaTransfer(
                transferId: transfer.transferId, mediaId: created.mediaId,
                uploadOffset: offset, state: "uploading", error: nil
            )
        }
        guard let mediaId else { throw MediaCacheError.invalidState }
        if let thumbnail = try await cache.uploadThumbnail(for: transfer) {
            try await api.uploadThumbnail(mediaId: mediaId, bytes: thumbnail, token: token)
        }
        while offset < Int64(data.count) {
            try Task.checkCancellation()
            let end = min(data.count, Int(offset) + chunkSize)
            let response = try await api.uploadChunk(
                mediaId: mediaId, offset: offset, bytes: Data(data[Int(offset)..<end]), token: token
            )
            guard response.mediaId == mediaId, response.uploadOffset == Int64(end) else {
                throw MediaCacheError.invalidState
            }
            offset = response.uploadOffset
            try await localStore.updateMediaTransfer(
                transferId: transfer.transferId, mediaId: mediaId,
                uploadOffset: offset, state: "uploading", error: nil
            )
            await progress(Double(offset) / Double(max(1, data.count)))
        }
        let completed = try await api.completeUpload(mediaId: mediaId, token: token)
        guard completed.mediaId == mediaId, completed.ready else { throw MediaCacheError.invalidState }
        return mediaId
    }

    func finishUpload(_ transfer: MediaTransferRecord) async {
        try? await cache?.finishUpload(transfer)
    }

    func cancelUpload(_ transfer: MediaTransferRecord, token: String) async {
        if let mediaId = transfer.mediaId {
            // Cancellation cleanup must still run when the parent transfer task is already cancelled.
            let api = self.api
            await Task.detached { try? await api.cancelUpload(mediaId: mediaId, token: token) }.value
        }
        try? await cache?.finishUpload(transfer)
    }

    func discardPrepared(_ prepared: PreparedMediaUpload) async {
        await cache?.discardPrepared(prepared)
    }

    func thumbnail(media: CloudMedia, token: String) async throws -> Data? {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        if let transferId = Self.pendingTransferId(media.id) {
            return try await cache.preparedThumbnail(transferId: transferId)
        }
        guard media.hasThumbnail else { return nil }
        if let cached = try await cache.thumbnail(mediaId: media.id) { return cached }
        let data = try await api.downloadThumbnail(mediaId: media.id, token: token)
        try await cache.storeThumbnail(data, mediaId: media.id)
        return data
    }

    func data(media: CloudMedia, token: String, progress: @Sendable (Double) async -> Void = { _ in }) async throws -> Data {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        if let transferId = Self.pendingTransferId(media.id) {
            return try await cache.preparedData(transferId: transferId)
        }
        guard media.byteSize > 0, media.byteSize <= 25 * 1024 * 1024 else { throw MediaCacheError.unsupportedSize }
        if let cached = try await cache.downloadedData(mediaId: media.id, expectedSize: media.byteSize) { return cached }
        var offset = try await cache.contiguousDownloadOffset(mediaId: media.id)
        while offset < media.byteSize {
            try Task.checkCancellation()
            let chunk = try await api.downloadChunk(mediaId: media.id, offset: offset, token: token)
            guard chunk.nextOffset > offset, chunk.totalSize == media.byteSize else { throw MediaCacheError.invalidState }
            try await cache.storeDownloadChunk(chunk.data, mediaId: media.id, offset: offset)
            offset = chunk.nextOffset
            await progress(Double(offset) / Double(max(1, media.byteSize)))
        }
        guard let result = try await cache.downloadedData(mediaId: media.id, expectedSize: media.byteSize) else {
            throw MediaCacheError.invalidState
        }
        return result
    }

    func clearCache() async { try? await cache?.clearAll() }

    func clearDownloadedCache() async { try? await cache?.clearDownloaded() }

    func cacheUsageBytes() async -> Int64 { (try? await cache?.downloadedUsageBytes()) ?? 0 }

    func temporaryPreview(data: Data, fileExtension: String?) async throws -> URL {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        return try await cache.createTemporaryPreview(data, fileExtension: fileExtension)
    }

    func removeTemporaryPreview(_ url: URL) async { await cache?.removeTemporaryPreview(url) }

    nonisolated private static func pendingTransferId(_ mediaId: String) -> String? {
        let prefix = "pending:"
        guard mediaId.hasPrefix(prefix) else { return nil }
        let value = String(mediaId.dropFirst(prefix.count))
        return value.isEmpty ? nil : value
    }
}

enum MediaCacheError: LocalizedError {
    case unsupportedSize, thumbnailTooLarge, localQuotaExceeded, encryptionFailed, invalidState, uploadExpired

    var errorDescription: String? {
        switch self {
        case .unsupportedSize: String(localized: "This file is empty or larger than 25 MB")
        case .thumbnailTooLarge: String(localized: "The media preview is too large")
        case .localQuotaExceeded: String(localized: "Toj needs more free media storage on this device")
        case .encryptionFailed: String(localized: "Could not encrypt the local media")
        case .invalidState: String(localized: "The media transfer could not be resumed")
        case .uploadExpired: String(localized: "The upload expired and must be restarted")
        }
    }
}

@MainActor
@Observable
final class VoiceNoteRecorder: NSObject, AVAudioRecorderDelegate {
    private(set) var isRecording = false
    private(set) var elapsedSeconds = 0
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private let recordingsDirectory: URL

    override init() {
        let fileManager = FileManager.default
        var directory = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appending(path: "TojVoiceRecordings", directoryHint: .isDirectory)
        try? fileManager.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete]
        )
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? directory.setResourceValues(values)
        if let stale = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            for url in stale { try? fileManager.removeItem(at: url) }
        }
        recordingsDirectory = directory
        super.init()
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(stopForInterruption),
            name: AVAudioSession.interruptionNotification, object: nil
        )
        center.addObserver(
            self, selector: #selector(stopForInterruption),
            name: UIApplication.didEnterBackgroundNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func stopForInterruption() { cancel() }

    func start() async throws {
        if isRecording { cancel() }
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { throw VoiceRecorderError.permissionDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = recordingsDirectory.appending(path: "toj-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            try FileManager.default.setAttributes(
                [.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path
            )
            recorder.delegate = self
            guard recorder.prepareToRecord(), recorder.record() else {
                recorder.stop()
                throw VoiceRecorderError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            elapsedSeconds = 0
            isRecording = true
            timer = .scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.elapsedSeconds += 1 }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    func finish() throws -> (data: Data, durationMs: Int64) {
        guard let recorder, let url = recordingURL else { throw VoiceRecorderError.notRecording }
        let duration = Int64(recorder.currentTime * 1_000)
        stopSession()
        let data = try Data(contentsOf: url)
        try? FileManager.default.removeItem(at: url)
        guard duration >= 300, !data.isEmpty else { throw VoiceRecorderError.tooShort }
        return (data, duration)
    }

    func cancel() {
        recorder?.stop()
        if let recordingURL { try? FileManager.default.removeItem(at: recordingURL) }
        stopSession()
    }

    private func stopSession() {
        recorder?.stop()
        recorder = nil
        timer?.invalidate()
        timer = nil
        recordingURL = nil
        isRecording = false
        elapsedSeconds = 0
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

enum VoiceRecorderError: LocalizedError {
    case permissionDenied, couldNotStart, notRecording, tooShort
    var errorDescription: String? {
        switch self {
        case .permissionDenied: String(localized: "Microphone access is required for voice messages")
        case .couldNotStart: String(localized: "Could not start recording")
        case .notRecording: String(localized: "No recording is active")
        case .tooShort: String(localized: "Hold a little longer to record a voice message")
        }
    }
}
