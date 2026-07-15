import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import Observation
import UIKit
import UniformTypeIdentifiers

nonisolated struct SafeDecodedImage {
    let image: UIImage
    let pixelWidth: Int
    let pixelHeight: Int
}

nonisolated struct PreparedPhotoUpload: Sendable {
    let data: Data
    let thumbnail: Data?
    let pixelWidth: Int
    let pixelHeight: Int
    let contentType: String
    let filenameExtension: String
}

nonisolated struct DetectedVideoContainer: Equatable, Sendable {
    let contentType: String
    let filenameExtension: String
}

enum SafeMediaVideoInspector {
    nonisolated static func container(for data: Data) -> DetectedVideoContainer? {
        guard data.count >= 12 else { return nil }
        let bytes = [UInt8](data.prefix(12))
        if bytes[0...3].elementsEqual([0x1a, 0x45, 0xdf, 0xa3]) {
            return DetectedVideoContainer(contentType: "video/webm", filenameExtension: "webm")
        }
        guard bytes[4...7].elementsEqual([0x66, 0x74, 0x79, 0x70]) else { return nil }
        let brand = String(bytes: bytes[8...11], encoding: .ascii)
        if brand == "qt  " {
            return DetectedVideoContainer(contentType: "video/quicktime", filenameExtension: "mov")
        }
        return DetectedVideoContainer(contentType: "video/mp4", filenameExtension: "mp4")
    }
}

enum SafeMediaFileMetadata {
    nonisolated static func sanitizedFileName(_ rawValue: String) -> String? {
        let normalized = rawValue.replacingOccurrences(of: "\\", with: "/")
        guard let leaf = normalized.split(separator: "/").last.map(String.init) else { return nil }
        let trimmed = leaf.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.lengthOfBytes(using: .utf8) <= 255,
              trimmed.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) })
        else { return nil }
        return trimmed
    }
}

enum SafeMediaImageDecoder {
    nonisolated private static let maxDimension = 8_192
    nonisolated private static let maxPixels = 40_000_000

    nonisolated static func decode(_ data: Data, maxPixelSize: Int) -> SafeDecodedImage? {
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

    nonisolated static func preparePhotoUpload(_ data: Data) -> PreparedPhotoUpload? {
        guard
            let source = CGImageSourceCreateWithData(
                data as CFData,
                [kCGImageSourceShouldCache: false] as CFDictionary
            ),
            CGImageSourceGetType(source) != nil,
            let decoded = decode(data, maxPixelSize: 2_560),
            let cgImage = decoded.image.cgImage
        else { return nil }
        let image = UIImage(cgImage: cgImage)
        var encoded: Data?
        for quality in [0.86, 0.78, 0.68] {
            guard let candidate = image.jpegData(compressionQuality: quality) else { continue }
            encoded = candidate
            if candidate.count <= 3 * 1024 * 1024 { break }
        }
        guard let encoded, !encoded.isEmpty else { return nil }
        return PreparedPhotoUpload(
            data: encoded,
            thumbnail: thumbnailData(image),
            pixelWidth: cgImage.width,
            pixelHeight: cgImage.height,
            contentType: "image/jpeg",
            filenameExtension: "jpg"
        )
    }

    nonisolated static func thumbnailData(_ image: UIImage) -> Data? {
        for dimension in [640.0, 480.0, 320.0] {
            guard let resized = image.preparingThumbnail(
                of: CGSize(width: dimension, height: dimension)
            ) else { continue }
            for quality in [0.72, 0.55, 0.4] {
                if let data = resized.jpegData(compressionQuality: quality), data.count <= 256 * 1024 {
                    return data
                }
            }
        }
        return nil
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
    let uploadProtocol: String?
    let partSize: Int?
    let totalParts: Int?
    let receivedParts: [Int]?
}

nonisolated struct MediaUploadState: Codable, Sendable {
    let mediaId: String
    let uploadOffset: Int64
    let byteSize: Int64
    let status: String
    let expiresAt: String
    let chunkSize: Int
    let uploadProtocol: String?
    let partSize: Int?
    let totalParts: Int?
    let receivedParts: [Int]?
}

nonisolated struct MediaChunkResponse: Codable, Sendable {
    let mediaId: String
    let uploadOffset: Int64
    let complete: Bool
    let duplicate: Bool
}

nonisolated struct MediaPartResponse: Codable, Sendable {
    let mediaId: String
    let partIndex: Int
    let receivedBytes: Int64
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
    let uploadProtocol: String?
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

    func uploadPart(
        mediaId: String, partIndex: Int, bytes: Data, token: String,
        progress: @escaping @Sendable (Int64, Int64) async -> Void
    ) async throws -> MediaPartResponse {
        var request = URLRequest(url: config.httpURL(path: "v1/media/uploads/\(mediaId)/parts/\(partIndex)"))
        request.httpMethod = "PUT"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let delegate = MediaUploadTaskDelegate(progress: progress)
        let (data, response) = try await session.upload(for: request, from: bytes, delegate: delegate)
        _ = try validate(data: data, response: response)
        return try JSONDecoder().decode(MediaPartResponse.self, from: data)
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
            let payload = try? JSONDecoder().decode(MediaServerError.self, from: data)
            let message = payload?.error ?? "HTTP \(http.statusCode)"
            throw CloudAPIError(
                status: http.statusCode, message: message,
                retryAfter: http.value(forHTTPHeaderField: "Retry-After").flatMap(Int.init),
                code: payload?.code
            )
        }
        return http
    }
}

private struct EmptyMediaBody: Codable {}
private struct MediaThumbnailResponse: Codable { let mediaId: String; let uploaded: Bool }
private struct MediaCancelResponse: Codable { let mediaId: String; let cancelled: Bool }
private struct MediaServerError: Codable { let error: String; let code: String? }
nonisolated struct MediaDownloadChunk: Sendable { let data: Data; let nextOffset: Int64; let totalSize: Int64 }

private final class MediaUploadTaskDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    private let progress: @Sendable (Int64, Int64) async -> Void

    init(progress: @escaping @Sendable (Int64, Int64) async -> Void) {
        self.progress = progress
    }

    func urlSession(
        _ session: URLSession, task: URLSessionTask, didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64, totalBytesExpectedToSend: Int64
    ) {
        Task { await progress(totalBytesSent, totalBytesExpectedToSend) }
    }
}

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

    /// Returns decrypted bytes for `[offset, offset+length)` iff every byte in that range is already
    /// cached (chunks are contiguous across it); otherwise `nil`. Chunk plaintext sizes are derived
    /// from the sealed file size (AES-GCM `.combined` adds a fixed 28-byte nonce+tag) so coverage can
    /// be computed without decrypting chunks outside the requested window. Enables streaming playback.
    func cachedByteRange(mediaId: String, offset start: Int64, length: Int64) throws -> Data? {
        guard length > 0 else { return Data() }
        let end = start + length
        let entries = try sortedChunkExtents(mediaId: mediaId)
        guard !entries.isEmpty else { return nil }
        var result = Data(capacity: Int(length))
        var pos = start
        for entry in entries {
            let chunkEnd = entry.offset + entry.size
            if chunkEnd <= pos { continue }        // fully before the cursor
            if entry.offset > pos { break }        // gap: `pos` is not covered
            let plaintext = try readEncrypted(
                from: chunkURL(mediaId: mediaId, offset: entry.offset),
                aad: "download|\(mediaId)|\(entry.offset)"
            )
            let localStart = Int(pos - entry.offset)
            let localEnd = Int(min(chunkEnd, end) - entry.offset)
            guard localStart >= 0, localEnd <= plaintext.count, localStart <= localEnd else { return nil }
            result.append(plaintext.subdata(in: localStart..<localEnd))
            pos = chunkEnd
            if pos >= end { break }
        }
        guard pos >= end else { return nil }
        try? touch(downloadDirectory(mediaId))
        return result
    }

    /// How far contiguous cached coverage extends from `start` (returns `start` when nothing is
    /// cached there). The engine downloads the next chunk at this offset to grow the covered range.
    func coverageEnd(mediaId: String, from start: Int64) throws -> Int64 {
        let entries = try sortedChunkExtents(mediaId: mediaId)
        var pos = start
        for entry in entries {
            let chunkEnd = entry.offset + entry.size
            if chunkEnd <= pos { continue }
            if entry.offset > pos { break }
            pos = chunkEnd
        }
        return pos
    }

    private func sortedChunkExtents(mediaId: String) throws -> [(offset: Int64, size: Int64)] {
        let dir = downloadDirectory(mediaId)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.fileSizeKey])
            .compactMap { url -> (offset: Int64, size: Int64)? in
                guard
                    let offset = Int64(url.deletingPathExtension().lastPathComponent),
                    let cipherSize = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                    cipherSize > Self.sealOverhead
                else { return nil }
                return (offset, Int64(cipherSize - Self.sealOverhead))
            }
            .sorted { $0.offset < $1.offset }
    }

    /// AES-GCM `.combined` layout overhead = 12-byte nonce + 16-byte tag.
    private static let sealOverhead = 28

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

nonisolated struct MediaMultipartPlan: Equatable, Sendable {
    let partSize: Int
    let totalParts: Int
    let receivedParts: Set<Int>

    init?(byteSize: Int64, partSize: Int?, totalParts: Int?, receivedParts: [Int]?) {
        guard byteSize > 0, let partSize, let totalParts,
              (256 * 1024...512 * 1024).contains(partSize),
              totalParts == Int((byteSize + Int64(partSize) - 1) / Int64(partSize))
        else { return nil }
        let received = Set(receivedParts ?? [])
        guard received.count == (receivedParts ?? []).count,
              received.allSatisfy({ (0..<totalParts).contains($0) })
        else { return nil }
        self.partSize = partSize
        self.totalParts = totalParts
        self.receivedParts = received
    }

    var missingParts: [Int] { (0..<totalParts).filter { !receivedParts.contains($0) } }

    func range(for partIndex: Int, byteSize: Int64) -> Range<Int> {
        let start = partIndex * partSize
        let end = min(Int(byteSize), start + partSize)
        return start..<end
    }
}

private actor MediaMultipartProgressTracker {
    private let totalBytes: Int64
    private let partSizes: [Int: Int64]
    private var acknowledged: Set<Int>
    private var sentByPart: [Int: Int64] = [:]
    private var maximumReported = 0.0

    init(totalBytes: Int64, partSizes: [Int: Int64], acknowledged: Set<Int>) {
        self.totalBytes = totalBytes
        self.partSizes = partSizes
        self.acknowledged = acknowledged
    }

    func reset(partIndex: Int) { sentByPart[partIndex] = 0 }

    func currentProgress() -> Double { nextProgress() }

    func sent(partIndex: Int, bytes: Int64) -> Double {
        guard !acknowledged.contains(partIndex) else { return maximumReported }
        sentByPart[partIndex] = min(max(0, bytes), partSizes[partIndex] ?? 0)
        return nextProgress()
    }

    func acknowledge(partIndex: Int) -> (progress: Double, acknowledgedBytes: Int64) {
        acknowledged.insert(partIndex)
        sentByPart[partIndex] = nil
        return (nextProgress(), acknowledged.reduce(0) { $0 + (partSizes[$1] ?? 0) })
    }

    private func nextProgress() -> Double {
        let acknowledgedBytes = acknowledged.reduce(Int64(0)) { $0 + (partSizes[$1] ?? 0) }
        let inFlightBytes = sentByPart.reduce(Int64(0)) { partial, entry in
            acknowledged.contains(entry.key) ? partial : partial + entry.value
        }
        let measured = Double(acknowledgedBytes + inFlightBytes) / Double(max(1, totalBytes))
        maximumReported = max(maximumReported, min(0.97, measured * 0.97))
        return maximumReported
    }
}

nonisolated enum MediaPartScheduler {
    static func run(
        partIndexes: [Int],
        maximumConcurrent: Int = 3,
        upload: @escaping @Sendable (Int) async throws -> Int64,
        didAcknowledge: @escaping @Sendable (Int, Int64) async throws -> Void
    ) async throws {
        guard !partIndexes.isEmpty else { return }
        let concurrency = max(1, min(maximumConcurrent, partIndexes.count))
        var nextIndex = 0
        try await withThrowingTaskGroup(of: (Int, Int64).self) { group in
            func enqueue(_ partIndex: Int) {
                group.addTask {
                    (partIndex, try await upload(partIndex))
                }
            }

            while nextIndex < concurrency {
                enqueue(partIndexes[nextIndex])
                nextIndex += 1
            }
            while let (partIndex, acknowledgedBytes) = try await group.next() {
                try await didAcknowledge(partIndex, acknowledgedBytes)
                if nextIndex < partIndexes.count {
                    enqueue(partIndexes[nextIndex])
                    nextIndex += 1
                }
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
        session: URLSession? = nil
    ) {
        self.api = CloudMediaAPI(config: config, session: session ?? Self.makeMediaSession())
        self.cache = cache ?? (try? EncryptedMediaCache())
    }

    nonisolated private static func makeMediaSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 60
        configuration.timeoutIntervalForResource = 15 * 60
        configuration.httpMaximumConnectionsPerHost = 3
        return URLSession(configuration: configuration)
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
        useMultipartV2: Bool = false,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> String {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        let data = try await cache.uploadData(for: transfer)
        var mediaId = transfer.mediaId
        var offset = transfer.uploadOffset
        var chunkSize = 256 * 1024
        var multipartPlan: MediaMultipartPlan?
        if let existingId = mediaId {
            do {
                let remote = try await api.uploadState(mediaId: existingId, token: token)
                if remote.status == "rejected" || remote.status == "deleted" {
                    try await localStore.resetMediaUpload(transferId: transfer.transferId)
                    mediaId = nil
                    offset = 0
                } else {
                    guard remote.status == "uploading" || remote.status == "ready" else {
                        throw MediaCacheError.uploadExpired
                    }
                guard
                    remote.mediaId == existingId, remote.byteSize == transfer.byteSize,
                    remote.uploadOffset >= 0, remote.uploadOffset <= transfer.byteSize,
                    remote.chunkSize > 0, remote.chunkSize <= 1024 * 1024,
                    remote.status != "ready" || remote.uploadOffset == transfer.byteSize
                else { throw MediaCacheError.invalidState }
                offset = remote.uploadOffset
                chunkSize = remote.chunkSize
                if remote.status == "ready" { return existingId }
                    if remote.uploadProtocol == "parts_v2" {
                        guard let plan = MediaMultipartPlan(
                            byteSize: transfer.byteSize, partSize: remote.partSize,
                            totalParts: remote.totalParts, receivedParts: remote.receivedParts
                        ) else { throw MediaCacheError.invalidState }
                        multipartPlan = plan
                    }
                }
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
                    width: transfer.width, height: transfer.height,
                    uploadProtocol: useMultipartV2 ? "parts_v2" : nil
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
            if created.uploadProtocol == "parts_v2" {
                guard let plan = MediaMultipartPlan(
                    byteSize: transfer.byteSize, partSize: created.partSize,
                    totalParts: created.totalParts, receivedParts: created.receivedParts
                ) else { throw MediaCacheError.invalidState }
                multipartPlan = plan
            }
            try await localStore.updateMediaTransfer(
                transferId: transfer.transferId, mediaId: created.mediaId,
                uploadOffset: offset, state: "uploading", error: nil
            )
        }
        guard let mediaId else { throw MediaCacheError.invalidState }
        let thumbnail = try await cache.uploadThumbnail(for: transfer)
        if let multipartPlan {
            async let thumbnailUpload: Void = uploadThumbnailIfPresent(
                thumbnail, mediaId: mediaId, token: token
            )
            try await uploadMultipart(
                data: data, transfer: transfer, mediaId: mediaId, token: token,
                plan: multipartPlan, localStore: localStore, progress: progress
            )
            try await thumbnailUpload
        } else {
            try await uploadThumbnailIfPresent(thumbnail, mediaId: mediaId, token: token)
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
                await progress(min(0.97, Double(offset) / Double(max(1, data.count)) * 0.97))
            }
        }
        let completed = try await api.completeUpload(mediaId: mediaId, token: token)
        guard completed.mediaId == mediaId, completed.ready else { throw MediaCacheError.invalidState }
        await progress(1)
        return mediaId
    }

    private func uploadThumbnailIfPresent(_ thumbnail: Data?, mediaId: String, token: String) async throws {
        if let thumbnail { try await api.uploadThumbnail(mediaId: mediaId, bytes: thumbnail, token: token) }
    }

    private func uploadMultipart(
        data: Data, transfer: MediaTransferRecord, mediaId: String, token: String,
        plan: MediaMultipartPlan, localStore: CloudLocalStore,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws {
        let partSizes = Dictionary(uniqueKeysWithValues: (0..<plan.totalParts).map { index in
            (index, Int64(plan.range(for: index, byteSize: transfer.byteSize).count))
        })
        let tracker = MediaMultipartProgressTracker(
            totalBytes: transfer.byteSize, partSizes: partSizes, acknowledged: plan.receivedParts
        )
        if !plan.receivedParts.isEmpty {
            let initial = await tracker.currentProgress()
            await progress(initial)
        }
        let missing = plan.missingParts
        let api = self.api
        try await MediaPartScheduler.run(
            partIndexes: missing,
            upload: { partIndex in
                let range = plan.range(for: partIndex, byteSize: transfer.byteSize)
                let bytes = Data(data[range])
                let response = try await Self.uploadPartWithRetry(
                    api: api, mediaId: mediaId, partIndex: partIndex,
                    bytes: bytes, token: token, tracker: tracker, progress: progress
                )
                guard response.mediaId == mediaId, response.partIndex == partIndex else {
                    throw MediaCacheError.invalidState
                }
                let acknowledged = await tracker.acknowledge(partIndex: partIndex)
                await progress(acknowledged.progress)
                return acknowledged.acknowledgedBytes
            },
            didAcknowledge: { _, acknowledgedBytes in
                try await localStore.updateMediaTransfer(
                    transferId: transfer.transferId, mediaId: mediaId,
                    uploadOffset: acknowledgedBytes, state: "uploading", error: nil
                )
            }
        )
    }

    nonisolated private static func uploadPartWithRetry(
        api: CloudMediaAPI, mediaId: String, partIndex: Int, bytes: Data, token: String,
        tracker: MediaMultipartProgressTracker,
        progress: @escaping @Sendable (Double) async -> Void
    ) async throws -> MediaPartResponse {
        var attempt = 0
        while true {
            try Task.checkCancellation()
            await tracker.reset(partIndex: partIndex)
            do {
                return try await api.uploadPart(
                    mediaId: mediaId, partIndex: partIndex, bytes: bytes, token: token,
                    progress: { sent, _ in
                        let value = await tracker.sent(partIndex: partIndex, bytes: sent)
                        await progress(value)
                    }
                )
            } catch {
                attempt += 1
                guard case let .transient(retryAfter) = cloudFailureDisposition(error), attempt < 3 else {
                    throw error
                }
                let delay = retryAfter ?? pow(2, Double(attempt - 1))
                try await Task.sleep(for: .seconds(delay))
            }
        }
    }

    func finishUpload(_ transfer: MediaTransferRecord) async {
        try? await cache?.finishUpload(transfer)
    }

    func discardTransfer(_ transfer: MediaTransferRecord) async {
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

    /// Serves `[offset, offset+length)` decrypted, downloading (and caching) only the chunks that
    /// range needs — the streaming primitive behind `AVAssetResourceLoader`. Unlike `data`, it never
    /// requires the whole file, so playback starts after the first covering chunk and seeks fetch
    /// only their target region. Requests are clamped to the media's real byte size.
    func byteRange(media: CloudMedia, token: String, offset: Int64, length: Int64) async throws -> Data {
        guard let cache else { throw MediaCacheError.encryptionFailed }
        if let transferId = Self.pendingTransferId(media.id) {
            // Just-sent media is already fully local — slice it in memory.
            let full = try await cache.preparedData(transferId: transferId)
            return Self.slice(full, offset: offset, length: length)
        }
        let total = media.byteSize
        guard total > 0, total <= 25 * 1024 * 1024 else { throw MediaCacheError.unsupportedSize }
        let start = max(0, offset)
        let end = min(total, start + max(0, length))
        guard end > start else { return Data() }
        let wanted = end - start
        while true {
            if let data = try await cache.cachedByteRange(mediaId: media.id, offset: start, length: wanted) {
                return data
            }
            try Task.checkCancellation()
            let downloadAt = try await cache.coverageEnd(mediaId: media.id, from: start)
            guard downloadAt < end, downloadAt < total else { throw MediaCacheError.invalidState }
            let chunk = try await api.downloadChunk(mediaId: media.id, offset: downloadAt, token: token)
            guard chunk.nextOffset > downloadAt, chunk.totalSize == total else { throw MediaCacheError.invalidState }
            try await cache.storeDownloadChunk(chunk.data, mediaId: media.id, offset: downloadAt)
        }
    }

    /// Builds an `AVURLAsset` that streams this media through `EncryptedMediaResourceLoader`. The
    /// returned owner must be retained for the lifetime of playback (the asset holds the delegate weakly).
    nonisolated func makeStreamingAsset(media: CloudMedia, token: String) -> StreamingMediaAsset {
        StreamingMediaAsset(media: media, token: token, engine: self)
    }

    nonisolated private static func slice(_ data: Data, offset: Int64, length: Int64) -> Data {
        let start = Int(max(0, min(Int64(data.count), offset)))
        let end = Int(max(Int64(start), min(Int64(data.count), offset + max(0, length))))
        return data.subdata(in: start..<end)
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

/// Owns a streaming `AVURLAsset` and the resource-loader delegate that feeds it (the asset retains
/// the delegate only weakly, so this owner must outlive playback). Hand `asset` to an `AVPlayerItem`.
nonisolated final class StreamingMediaAsset {
    let asset: AVURLAsset
    private let delegate: EncryptedMediaResourceLoader
    private let queue = DispatchQueue(label: "com.toj.media.resource-loader")

    init(media: CloudMedia, token: String, engine: CloudMediaTransferEngine) {
        let ext = UTType(mimeType: media.contentType)?.preferredFilenameExtension ?? "mp4"
        let url = URL(string: "\(EncryptedMediaResourceLoader.scheme)://stream/\(UUID().uuidString).\(ext)")!
        asset = AVURLAsset(url: url)
        delegate = EncryptedMediaResourceLoader(media: media, token: token, engine: engine)
        asset.resourceLoader.setDelegate(delegate, queue: queue)
    }
}

/// Bridges `AVPlayer`'s byte-range requests to the encrypted chunk store via `engine.byteRange`,
/// so video streams (plays before it is fully downloaded) straight from Toj's own chunk API.
/// Delegate callbacks are serialized on the loader queue supplied to `setDelegate(_:queue:)`.
nonisolated final class EncryptedMediaResourceLoader: NSObject, AVAssetResourceLoaderDelegate, @unchecked Sendable {
    static let scheme = "toj-media"
    private let media: CloudMedia
    private let token: String
    private let engine: CloudMediaTransferEngine
    private var tasks: [ObjectIdentifier: Task<Void, Never>] = [:]

    init(media: CloudMedia, token: String, engine: CloudMediaTransferEngine) {
        self.media = media
        self.token = token
        self.engine = engine
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        shouldWaitForLoadingOfRequestedResource loadingRequest: AVAssetResourceLoadingRequest
    ) -> Bool {
        let key = ObjectIdentifier(loadingRequest)
        let media = media, token = token, engine = engine
        tasks[key] = Task {
            do {
                if let info = loadingRequest.contentInformationRequest {
                    info.contentType = UTType(mimeType: media.contentType)?.identifier ?? UTType.mpeg4Movie.identifier
                    info.isByteRangeAccessSupported = true
                    info.contentLength = media.byteSize
                }
                if let dataRequest = loadingRequest.dataRequest {
                    var pos = dataRequest.currentOffset
                    let end = dataRequest.requestsAllDataToEndOfResource
                        ? media.byteSize
                        : dataRequest.requestedOffset + Int64(dataRequest.requestedLength)
                    while pos < end {
                        try Task.checkCancellation()
                        let sliceLength = min(Int64(512 * 1024), end - pos)
                        let data = try await engine.byteRange(media: media, token: token, offset: pos, length: sliceLength)
                        if data.isEmpty { break }
                        dataRequest.respond(with: data)
                        pos += Int64(data.count)
                    }
                }
                loadingRequest.finishLoading()
            } catch is CancellationError {
                // The player abandoned this request (seek/teardown); nothing to report.
            } catch {
                loadingRequest.finishLoading(with: error)
            }
        }
        return true
    }

    func resourceLoader(
        _ resourceLoader: AVAssetResourceLoader,
        didCancel loadingRequest: AVAssetResourceLoadingRequest
    ) {
        let key = ObjectIdentifier(loadingRequest)
        tasks[key]?.cancel()
        tasks[key] = nil
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
    private(set) var level: Float = 0
    var onUnexpectedStop: (() -> Void)?
    private var recorder: AVAudioRecorder?
    private var timer: Timer?
    private var recordingURL: URL?
    private let recordingsDirectory: URL
    private var previousCategory: AVAudioSession.Category?
    private var previousMode: AVAudioSession.Mode?
    private var previousOptions: AVAudioSession.CategoryOptions = []

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
        center.addObserver(
            self, selector: #selector(routeChanged(_:)),
            name: AVAudioSession.routeChangeNotification, object: nil
        )
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    @objc private func stopForInterruption() {
        guard isRecording else { return }
        cancel()
        onUnexpectedStop?()
    }

    @objc private func routeChanged(_ notification: Notification) {
        guard isRecording,
              let raw = notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt,
              let reason = AVAudioSession.RouteChangeReason(rawValue: raw),
              reason == .oldDeviceUnavailable || AVAudioSession.sharedInstance().availableInputs?.isEmpty == true
        else { return }
        cancel()
        onUnexpectedStop?()
    }

    func start() async throws {
        if isRecording { cancel() }
        let permission = await AVAudioApplication.requestRecordPermission()
        guard permission else { throw VoiceRecorderError.permissionDenied }
        let session = AVAudioSession.sharedInstance()
        previousCategory = session.category
        previousMode = session.mode
        previousOptions = session.categoryOptions
        try session.setCategory(.playAndRecord, mode: .spokenAudio, options: [.defaultToSpeaker, .allowBluetoothHFP])
        try session.setActive(true)
        let url = recordingsDirectory.appending(path: "toj-voice-\(UUID().uuidString).m4a")
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
        ]
        do {
            try Self.createProtectedRecordingFile(at: url)
            let recorder = try AVAudioRecorder(url: url, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            guard recorder.prepareToRecord(), recorder.record() else {
                recorder.stop()
                throw VoiceRecorderError.couldNotStart
            }
            self.recorder = recorder
            recordingURL = url
            elapsedSeconds = 0
            level = 0
            isRecording = true
            timer = .scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, let recorder = self.recorder else { return }
                    recorder.updateMeters()
                    let decibels = recorder.averagePower(forChannel: 0)
                    self.level = max(0.03, min(1, pow(10, decibels / 32)))
                    self.elapsedSeconds = Int(recorder.currentTime)
                }
            }
        } catch {
            try? FileManager.default.removeItem(at: url)
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
    }

    nonisolated static func createProtectedRecordingFile(
        at url: URL,
        fileManager: FileManager = .default
    ) throws {
        guard fileManager.createFile(
            atPath: url.path,
            contents: Data(),
            attributes: [.protectionKey: FileProtectionType.complete]
        ) else {
            throw VoiceRecorderError.couldNotStart
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
        level = 0
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let previousCategory, let previousMode {
            try? session.setCategory(previousCategory, mode: previousMode, options: previousOptions)
        }
        previousCategory = nil
        previousMode = nil
        previousOptions = []
    }
}

enum VoiceRecorderError: LocalizedError, Equatable {
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
