import type { SQL } from "bun";
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import {
  mediaChunkAAD, mediaDigestHMAC, mediaFileNameAAD, mediaThumbnailAAD, open, seal,
} from "./crypto";
import { requireActiveDevice } from "./auth";

export class MediaError extends Error {
  constructor(
    message: string,
    readonly status = 400,
    readonly code = "invalid_media_request",
    readonly retryAfter?: number,
  ) {
    super(message);
  }
}

export type MediaKind = "photo" | "video" | "file" | "voice";

export type MediaDTO = {
  id: string;
  kind: MediaKind;
  content_type: string;
  file_name: string | null;
  byte_size: number;
  duration_ms: number | null;
  width: number | null;
  height: number | null;
  has_thumbnail: boolean;
};

export const DEFAULT_MEDIA_CHUNK_BYTES = 1024 * 1024;
export const MEDIA_PART_SIZE = 256 * 1024;
export const LARGE_MEDIA_PART_SIZE = 512 * 1024;
export const LARGE_MEDIA_THRESHOLD = 10 * 1024 * 1024;
const DEFAULT_MAX_OBJECT_BYTES = 25 * 1024 * 1024;
const DEFAULT_ACCOUNT_QUOTA_BYTES = 250 * 1024 * 1024;
const MAX_THUMBNAIL_BYTES = 256 * 1024;
const DEFAULT_MAX_ACTIVE_UPLOADS = 10;
const DEFAULT_MAX_DAILY_UPLOADS = 100;
const MAX_IMAGE_DIMENSION = 8_192;
const MAX_IMAGE_PIXELS = 40_000_000;
const MAX_THUMBNAIL_DIMENSION = 2_048;
const MAX_THUMBNAIL_PIXELS = 4_000_000;
const MAX_IMAGE_HEADER_BYTES = 256 * 1024;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const CONTENT_TYPE_PATTERN = /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/i;
const KINDS = new Set<MediaKind>(["photo", "video", "file", "voice"]);

const n = (value: unknown) => Number(value as any);
const buf = (value: unknown) => Buffer.from(value as Uint8Array);

async function requireActiveMediaAccount(sql: SQL, accountId: string): Promise<void> {
  const rows = await sql`
    SELECT id FROM accounts
    WHERE id = ${accountId} AND status IN ('active','limited')
    FOR SHARE`;
  if (!rows.length) throw new MediaError("account unavailable", 403);
}

function boundedEnv(name: string, fallback: number, lower: number, upper: number): number {
  const parsed = Number(process.env[name] ?? fallback);
  return Number.isSafeInteger(parsed) && parsed >= lower && parsed <= upper ? parsed : fallback;
}

export function mediaLimits() {
  return {
    chunkBytes: boundedEnv("TOJ_MEDIA_CHUNK_BYTES", DEFAULT_MEDIA_CHUNK_BYTES, 64 * 1024, 1024 * 1024),
    maxObjectBytes: boundedEnv("TOJ_MEDIA_MAX_OBJECT_BYTES", DEFAULT_MAX_OBJECT_BYTES, 1024, 100 * 1024 * 1024),
    accountQuotaBytes: boundedEnv("TOJ_MEDIA_ACCOUNT_QUOTA_BYTES", DEFAULT_ACCOUNT_QUOTA_BYTES, 1024, 10 * 1024 * 1024 * 1024),
    maxActiveUploads: boundedEnv("TOJ_MEDIA_MAX_ACTIVE_UPLOADS", DEFAULT_MAX_ACTIVE_UPLOADS, 1, 100),
    maxDailyUploads: boundedEnv("TOJ_MEDIA_MAX_DAILY_UPLOADS", DEFAULT_MAX_DAILY_UPLOADS, 1, 10_000),
    thumbnailBytes: MAX_THUMBNAIL_BYTES,
  };
}

function cleanFileName(value: unknown): string | null {
  if (value == null || value === "") return null;
  if (typeof value !== "string") throw new MediaError("invalid file name");
  const leaf = value.replace(/\\/g, "/").split("/").pop()!.trim();
  if (!leaf || Buffer.byteLength(leaf, "utf8") > 255 || /[\u0000-\u001f\u007f]/.test(leaf)) {
    throw new MediaError("invalid file name");
  }
  return leaf;
}

function optionalPositiveInt(value: unknown, name: string): number | null {
  if (value == null) return null;
  const parsed = Number(value);
  if (!Number.isSafeInteger(parsed) || parsed < 0 || parsed > 2_147_483_647) {
    throw new MediaError(`invalid ${name}`);
  }
  return parsed;
}

function toDTO(row: any): MediaDTO {
  const encryptedFileName = row.file_name_ciphertext == null ? null : open(
    {
      keyId: row.file_name_key_id,
      nonce: buf(row.file_name_nonce),
      ciphertext: buf(row.file_name_ciphertext),
    },
    mediaFileNameAAD(row.id),
  ).toString("utf8");
  return {
    id: row.id,
    kind: row.kind,
    content_type: row.content_type,
    file_name: encryptedFileName ?? row.file_name ?? null,
    byte_size: n(row.byte_size),
    duration_ms: row.duration_ms == null ? null : n(row.duration_ms),
    width: row.width == null ? null : n(row.width),
    height: row.height == null ? null : n(row.height),
    has_thumbnail: row.thumbnail_ciphertext != null,
  };
}

export async function loadMediaDTO(sql: SQL, mediaId: string | null): Promise<MediaDTO | null> {
  if (!mediaId) return null;
  const row = (await sql`
    SELECT id, kind, content_type, file_name, file_name_key_id, file_name_nonce,
           file_name_ciphertext, byte_size, duration_ms, width, height, thumbnail_ciphertext
    FROM media_objects WHERE id = ${mediaId} AND status = 'ready'`)[0];
  return row ? toDTO(row) : null;
}

export async function createMediaUpload(sql: SQL, accountId: string, deviceId: string, input: {
  kind?: unknown; contentType?: unknown; fileName?: unknown; byteSize?: unknown;
  sha256?: unknown; durationMs?: unknown; width?: unknown; height?: unknown;
  uploadProtocol?: unknown;
}) {
  const kind = String(input.kind ?? "") as MediaKind;
  if (!KINDS.has(kind)) throw new MediaError("unsupported media kind");
  const contentType = String(input.contentType ?? "").toLowerCase();
  if (!CONTENT_TYPE_PATTERN.test(contentType) || contentType.length > 127) {
    throw new MediaError("invalid content type");
  }
  if (kind === "photo" && !contentType.startsWith("image/")) throw new MediaError("photo content type required");
  if (kind === "video" && !contentType.startsWith("video/")) throw new MediaError("video content type required");
  if (kind === "voice" && !contentType.startsWith("audio/")) throw new MediaError("audio content type required");
  const byteSize = Number(input.byteSize);
  const uploadProtocol = input.uploadProtocol == null ? "offset_v1" : String(input.uploadProtocol);
  if (uploadProtocol !== "offset_v1" && uploadProtocol !== "parts_v2") {
    throw new MediaError("unsupported upload protocol", 400, "unsupported_upload_protocol");
  }
  const partSize = uploadProtocol === "parts_v2"
    ? (byteSize > LARGE_MEDIA_THRESHOLD ? LARGE_MEDIA_PART_SIZE : MEDIA_PART_SIZE)
    : null;
  const totalParts = partSize == null ? null : Math.ceil(byteSize / partSize);
  const { chunkBytes, maxObjectBytes, accountQuotaBytes, maxActiveUploads, maxDailyUploads } = mediaLimits();
  if (!Number.isSafeInteger(byteSize) || byteSize <= 0) throw new MediaError("invalid media size");
  if (byteSize > maxObjectBytes) {
    throw new MediaError("media exceeds the upload limit", 413, "media_too_large");
  }
  const sha256 = String(input.sha256 ?? "");
  if (!SHA256_PATTERN.test(sha256)) throw new MediaError("valid SHA-256 required");
  const fileName = cleanFileName(input.fileName);
  const durationMs = optionalPositiveInt(input.durationMs, "duration");
  const width = optionalPositiveInt(input.width, "width");
  const height = optionalPositiveInt(input.height, "height");
  if (width === 0 || height === 0) throw new MediaError("invalid media dimensions");
  if ((width != null || height != null) && (width == null || height == null)) {
    throw new MediaError("both media dimensions are required");
  }
  if (width != null && height != null &&
      (width > MAX_IMAGE_DIMENSION || height > MAX_IMAGE_DIMENSION || width * height > MAX_IMAGE_PIXELS)) {
    throw new MediaError("media dimensions exceed the limit", 413, "media_dimensions_too_large");
  }
  if (kind === "photo" && (width == null || height == null)) {
    throw new MediaError("photo dimensions are required");
  }
  if (kind === "video" && (width == null || height == null || durationMs == null || durationMs <= 0)) {
    throw new MediaError("video dimensions and duration are required");
  }
  if (kind === "voice" && (durationMs == null || durationMs <= 0)) {
    throw new MediaError("voice duration is required");
  }
  if (durationMs != null && durationMs > 3_600_000) {
    throw new MediaError("media duration exceeds the limit", 413, "media_duration_too_long");
  }

  return await sql.begin(async (tx) => {
    const owner = await tx`SELECT id FROM accounts WHERE id = ${accountId} AND status IN ('active','limited') FOR UPDATE`;
    if (!owner.length) throw new MediaError("account unavailable", 403);
    await requireActiveDevice(tx, accountId, deviceId);
    const counts = (await tx`
      SELECT
        (SELECT count(*) FROM media_objects
         WHERE owner_account_id = ${accountId} AND status = 'uploading' AND expires_at > now()) AS active,
        (SELECT count(*) FROM media_upload_attempts
         WHERE account_id = ${accountId} AND created_at > now() - interval '24 hours') AS daily`)[0];
    if (n(counts.active) >= maxActiveUploads) {
      throw new MediaError(
        "too many active uploads; finish or cancel one first", 429, "media_active_upload_limit", 30,
      );
    }
    if (n(counts.daily) >= maxDailyUploads) {
      throw new MediaError("daily media upload limit reached", 429, "media_daily_upload_limit", 3600);
    }
    const usage = (await tx`
      SELECT COALESCE(sum(byte_size), 0) AS bytes
      FROM media_objects
      WHERE owner_account_id = ${accountId}
        AND status IN ('uploading','ready') AND (status = 'ready' OR expires_at > now())`)[0];
    if (n(usage.bytes) + byteSize > accountQuotaBytes) {
      throw new MediaError("media storage quota exceeded", 413, "media_quota_exceeded");
    }
    await tx`INSERT INTO media_upload_attempts (account_id) VALUES (${accountId})`;
    const mediaId = randomUUID();
    const sealedFileName = fileName == null ? null : seal(fileName, mediaFileNameAAD(mediaId));
    const row = (await tx`
      INSERT INTO media_objects
        (id, owner_account_id, kind, content_type, file_name, file_name_key_id,
         file_name_nonce, file_name_ciphertext, byte_size, expected_sha256,
         duration_ms, width, height, upload_protocol, part_size, total_parts)
      VALUES (${mediaId}, ${accountId}, ${kind}, ${contentType}, NULL,
              ${sealedFileName?.keyId ?? null}, ${sealedFileName?.nonce ?? null},
              ${sealedFileName?.ciphertext ?? null}, ${byteSize},
              ${mediaDigestHMAC(Buffer.from(sha256, "hex"))}, ${durationMs}, ${width}, ${height},
              ${uploadProtocol}, ${partSize}, ${totalParts})
      RETURNING id, uploaded_bytes, expires_at`)[0];
    return {
      mediaId: row.id,
      uploadOffset: n(row.uploaded_bytes),
      chunkSize: chunkBytes,
      uploadProtocol,
      partSize,
      totalParts,
      receivedParts: [],
      expiresAt: row.expires_at instanceof Date ? row.expires_at.toISOString() : String(row.expires_at),
      quota: { usedBytes: n(usage.bytes) + byteSize, limitBytes: accountQuotaBytes },
    };
  });
}

export async function getMediaUpload(sql: SQL, accountId: string, mediaId: string) {
  const row = (await sql`
    SELECT id, uploaded_bytes, byte_size, status, expires_at,
           upload_protocol, part_size, total_parts
    FROM media_objects WHERE id = ${mediaId} AND owner_account_id = ${accountId}`)[0];
  if (!row) throw new MediaError("upload not found", 404);
  const receivedParts = row.upload_protocol === "parts_v2"
    ? (await sql`
        SELECT chunk_offset FROM media_chunks
        WHERE media_id = ${mediaId} ORDER BY chunk_offset`
      ).map((chunk) => Math.floor(n(chunk.chunk_offset) / n(row.part_size)))
    : [];
  return {
    mediaId: row.id, uploadOffset: n(row.uploaded_bytes), byteSize: n(row.byte_size),
    status: row.status,
    expiresAt: row.expires_at instanceof Date ? row.expires_at.toISOString() : String(row.expires_at),
    chunkSize: mediaLimits().chunkBytes,
    uploadProtocol: row.upload_protocol,
    partSize: row.part_size == null ? null : n(row.part_size),
    totalParts: row.total_parts == null ? null : n(row.total_parts),
    receivedParts,
  };
}

export async function uploadMediaPart(
  sql: SQL, accountId: string, deviceId: string, mediaId: string, partIndex: number, bytes: Buffer,
) {
  if (!Number.isSafeInteger(partIndex) || partIndex < 0) {
    throw new MediaError("invalid media part index", 400, "invalid_media_part");
  }
  if (bytes.length === 0 || bytes.length > LARGE_MEDIA_PART_SIZE) {
    throw new MediaError("invalid media part size", 413, "invalid_media_part_size");
  }
  const digest = mediaDigestHMAC(createHash("sha256").update(bytes).digest());
  return await sql.begin(async (tx) => {
    await requireActiveMediaAccount(tx, accountId);
    await requireActiveDevice(tx, accountId, deviceId);
    const row = (await tx`
      SELECT owner_account_id, byte_size, uploaded_bytes, status, expires_at,
             upload_protocol, part_size, total_parts
      FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) {
      throw new MediaError("upload not found", 404, "media_upload_not_found");
    }
    if (row.upload_protocol !== "parts_v2") {
      throw new MediaError("multipart upload unavailable", 409, "media_protocol_mismatch");
    }
    if (row.status !== "uploading") {
      throw new MediaError("upload is already complete", 409, "media_upload_unavailable");
    }
    if (new Date(row.expires_at).getTime() <= Date.now()) {
      throw new MediaError("upload expired", 410, "media_upload_expired");
    }
    const partSize = n(row.part_size);
    const totalParts = n(row.total_parts);
    if (partIndex >= totalParts) {
      throw new MediaError("invalid media part index", 400, "invalid_media_part");
    }
    const offset = partIndex * partSize;
    const expectedSize = partIndex === totalParts - 1 ? n(row.byte_size) - offset : partSize;
    if (bytes.length !== expectedSize) {
      throw new MediaError("invalid media part size", 413, "invalid_media_part_size");
    }
    const existing = (await tx`
      SELECT plain_size, plain_sha256 FROM media_chunks
      WHERE media_id = ${mediaId} AND chunk_offset = ${offset}`)[0];
    if (existing) {
      if (n(existing.plain_size) === bytes.length && timingSafeEqual(buf(existing.plain_sha256), digest)) {
        return {
          mediaId, partIndex, receivedBytes: n(row.uploaded_bytes),
          complete: n(row.uploaded_bytes) === n(row.byte_size), duplicate: true,
        };
      }
      throw new MediaError("media part conflict", 409, "media_part_conflict");
    }
    const sealed = seal(bytes, mediaChunkAAD(mediaId, offset));
    await tx`
      INSERT INTO media_chunks
        (media_id, chunk_offset, plain_size, plain_sha256, key_id, nonce, ciphertext)
      VALUES (${mediaId}, ${offset}, ${bytes.length}, ${digest}, ${sealed.keyId},
              ${sealed.nonce}, ${sealed.ciphertext})`;
    const uploadedBytes = n(row.uploaded_bytes) + bytes.length;
    await tx`UPDATE media_objects SET uploaded_bytes = ${uploadedBytes} WHERE id = ${mediaId}`;
    return {
      mediaId, partIndex, receivedBytes: uploadedBytes,
      complete: uploadedBytes === n(row.byte_size), duplicate: false,
    };
  });
}

export async function uploadMediaChunk(
  sql: SQL, accountId: string, deviceId: string, mediaId: string, offset: number, bytes: Buffer,
) {
  const { chunkBytes } = mediaLimits();
  if (!Number.isSafeInteger(offset) || offset < 0) throw new MediaError("invalid upload offset");
  if (bytes.length === 0 || bytes.length > chunkBytes) throw new MediaError("invalid media chunk size", 413);
  const digest = mediaDigestHMAC(createHash("sha256").update(bytes).digest());
  return await sql.begin(async (tx) => {
    await requireActiveMediaAccount(tx, accountId);
    await requireActiveDevice(tx, accountId, deviceId);
    const row = (await tx`
      SELECT owner_account_id, byte_size, uploaded_bytes, status, expires_at, upload_protocol
      FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) throw new MediaError("upload not found", 404);
    if (row.upload_protocol !== "offset_v1") {
      throw new MediaError("sequential upload unavailable", 409, "media_protocol_mismatch");
    }
    if (row.status !== "uploading") throw new MediaError("upload is already complete", 409);
    if (new Date(row.expires_at).getTime() <= Date.now()) {
      throw new MediaError("upload expired", 410, "media_upload_expired");
    }
    const uploaded = n(row.uploaded_bytes);
    if (offset < uploaded) {
      const existing = (await tx`
        SELECT plain_size, plain_sha256 FROM media_chunks
        WHERE media_id = ${mediaId} AND chunk_offset = ${offset}`)[0];
      if (existing && n(existing.plain_size) === bytes.length &&
          timingSafeEqual(buf(existing.plain_sha256), digest)) {
        return { mediaId, uploadOffset: uploaded, complete: uploaded === n(row.byte_size), duplicate: true };
      }
      throw new MediaError("upload offset conflict", 409);
    }
    if (offset !== uploaded) throw new MediaError("upload offset conflict", 409);
    if (offset + bytes.length > n(row.byte_size)) throw new MediaError("chunk exceeds declared media size", 413);
    const sealed = seal(bytes, mediaChunkAAD(mediaId, offset));
    await tx`
      INSERT INTO media_chunks
        (media_id, chunk_offset, plain_size, plain_sha256, key_id, nonce, ciphertext)
      VALUES (${mediaId}, ${offset}, ${bytes.length}, ${digest}, ${sealed.keyId},
              ${sealed.nonce}, ${sealed.ciphertext})`;
    const next = offset + bytes.length;
    await tx`UPDATE media_objects SET uploaded_bytes = ${next} WHERE id = ${mediaId}`;
    return { mediaId, uploadOffset: next, complete: next === n(row.byte_size), duplicate: false };
  });
}

export async function uploadMediaThumbnail(
  sql: SQL, accountId: string, deviceId: string, mediaId: string, contentType: string, bytes: Buffer,
) {
  if (!/^image\/(jpeg|png|webp)$/i.test(contentType)) throw new MediaError("unsupported thumbnail type");
  if (bytes.length === 0 || bytes.length > MAX_THUMBNAIL_BYTES) throw new MediaError("thumbnail too large", 413);
  validateImage(bytes, contentType, MAX_THUMBNAIL_DIMENSION, MAX_THUMBNAIL_PIXELS);
  const sealed = seal(bytes, mediaThumbnailAAD(mediaId));
  await sql.begin(async (tx) => {
    await requireActiveMediaAccount(tx, accountId);
    await requireActiveDevice(tx, accountId, deviceId);
    const rows = await tx`
      UPDATE media_objects
      SET thumbnail_key_id = ${sealed.keyId}, thumbnail_nonce = ${sealed.nonce},
          thumbnail_ciphertext = ${sealed.ciphertext}, thumbnail_byte_size = ${bytes.length},
          thumbnail_content_type = ${contentType.toLowerCase()}
      WHERE id = ${mediaId} AND owner_account_id = ${accountId} AND status = 'uploading'
      RETURNING id`;
    if (!rows.length) throw new MediaError("upload not found", 404);
  });
  return { mediaId, uploaded: true };
}

async function rejectUpload(sql: SQL, mediaId: string): Promise<void> {
  await sql`DELETE FROM media_chunks WHERE media_id = ${mediaId}`;
  await sql`
    UPDATE media_objects SET status = 'rejected', uploaded_bytes = 0,
      thumbnail_key_id = NULL, thumbnail_nonce = NULL, thumbnail_ciphertext = NULL,
      thumbnail_byte_size = NULL, thumbnail_content_type = NULL
    WHERE id = ${mediaId}`;
}

export async function completeMediaUpload(sql: SQL, accountId: string, deviceId: string, mediaId: string) {
  const result = await sql.begin(async (tx) => {
    await requireActiveMediaAccount(tx, accountId);
    await requireActiveDevice(tx, accountId, deviceId);
    const row = (await tx`
      SELECT owner_account_id, kind, content_type, byte_size, uploaded_bytes, expected_sha256,
             width, height, status, expires_at, upload_protocol, part_size, total_parts
      FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) throw new MediaError("upload not found", 404);
    if (row.status === "ready") return { mediaId, ready: true, duplicate: true };
    if (row.status !== "uploading") throw new MediaError("upload unavailable", 409);
    if (new Date(row.expires_at).getTime() <= Date.now()) {
      throw new MediaError("upload expired", 410, "media_upload_expired");
    }
    if (n(row.uploaded_bytes) !== n(row.byte_size)) {
      throw new MediaError("upload is incomplete", 409, "media_upload_incomplete");
    }
    const chunks = await tx`
      SELECT chunk_offset, plain_size, key_id, nonce, ciphertext
      FROM media_chunks WHERE media_id = ${mediaId} ORDER BY chunk_offset`;
    const hash = createHash("sha256");
    let header = Buffer.alloc(0);
    let expectedOffset = 0;
    let partIndex = 0;
    for (const chunk of chunks) {
      if (n(chunk.chunk_offset) !== expectedOffset) {
        throw new MediaError("upload has a missing chunk", 409, "media_upload_incomplete");
      }
      if (row.upload_protocol === "parts_v2") {
        const expectedPartSize = partIndex === n(row.total_parts) - 1
          ? n(row.byte_size) - partIndex * n(row.part_size)
          : n(row.part_size);
        if (n(chunk.chunk_offset) !== partIndex * n(row.part_size) || n(chunk.plain_size) !== expectedPartSize) {
          throw new MediaError("upload has an invalid part layout", 409, "media_part_layout_invalid");
        }
      }
      const plaintext = open(
        { keyId: chunk.key_id, nonce: buf(chunk.nonce), ciphertext: buf(chunk.ciphertext) },
        mediaChunkAAD(mediaId, expectedOffset),
      );
      if (plaintext.length !== n(chunk.plain_size)) throw new MediaError("upload chunk is corrupt", 409);
      if (header.length < MAX_IMAGE_HEADER_BYTES) {
        header = Buffer.concat([header, plaintext.subarray(0, MAX_IMAGE_HEADER_BYTES - header.length)]);
      }
      hash.update(plaintext);
      expectedOffset += plaintext.length;
      partIndex += 1;
    }
    if (row.upload_protocol === "parts_v2" && partIndex !== n(row.total_parts)) {
      throw new MediaError("upload has missing parts", 409, "media_upload_incomplete");
    }
    const digest = mediaDigestHMAC(hash.digest());
    if (expectedOffset !== n(row.byte_size) || !timingSafeEqual(digest, buf(row.expected_sha256))) {
      await rejectUpload(tx, mediaId);
      return { error: new MediaError("media checksum mismatch", 409, "media_checksum_mismatch") } as const;
    }
    try {
      validateMediaSignature(row.kind, row.content_type, header, row.width, row.height);
    } catch (error) {
      await rejectUpload(tx, mediaId);
      return { error: error instanceof MediaError ? error : new MediaError("invalid media", 415, "invalid_media") } as const;
    }
    await tx`
      UPDATE media_objects SET status = 'ready', completed_at = now(), expires_at = 'infinity'
      WHERE id = ${mediaId}`;
    return { mediaId, ready: true, duplicate: false } as const;
  });
  if ("error" in result) throw result.error;
  return result;
}

async function requireMediaAccess(sql: SQL, accountId: string, mediaId: string) {
  const row = (await sql`
    SELECT mo.id, mo.status, mo.byte_size, mo.content_type,
           mo.thumbnail_key_id, mo.thumbnail_nonce, mo.thumbnail_ciphertext,
           mo.thumbnail_content_type
    FROM media_objects mo
    WHERE mo.id = ${mediaId} AND EXISTS (
      SELECT 1 FROM messages m
      JOIN dialog_members dm ON dm.dialog_id = m.dialog_id
      WHERE m.media_id = mo.id AND m.state = 'visible'
        AND dm.account_id = ${accountId} AND dm.left_at IS NULL
    )
    FOR KEY SHARE OF mo`)[0];
  if (!row || row.status !== "ready") throw new MediaError("media not found", 404);
  return row;
}

export async function downloadMediaChunk(sql: SQL, accountId: string, mediaId: string, offset: number) {
  if (!Number.isSafeInteger(offset) || offset < 0) throw new MediaError("invalid download offset");
  return await sql.begin(async (tx) => {
    const object = await requireMediaAccess(tx, accountId, mediaId);
    if (offset === n(object.byte_size)) {
      return { bytes: Buffer.alloc(0), contentType: object.content_type, totalSize: n(object.byte_size), nextOffset: offset };
    }
    const chunk = (await tx`
      SELECT chunk_offset, plain_size, key_id, nonce, ciphertext
      FROM media_chunks WHERE media_id = ${mediaId} AND chunk_offset = ${offset}`)[0];
    if (!chunk) throw new MediaError("invalid download offset", 416);
    const bytes = open(
      { keyId: chunk.key_id, nonce: buf(chunk.nonce), ciphertext: buf(chunk.ciphertext) },
      mediaChunkAAD(mediaId, offset),
    );
    await tx`UPDATE media_objects SET last_accessed_at = now() WHERE id = ${mediaId}`;
    return {
      bytes, contentType: object.content_type, totalSize: n(object.byte_size),
      nextOffset: offset + bytes.length,
    };
  });
}

export async function downloadMediaThumbnail(sql: SQL, accountId: string, mediaId: string) {
  return await sql.begin(async (tx) => {
    const row = await requireMediaAccess(tx, accountId, mediaId);
    if (!row.thumbnail_ciphertext) throw new MediaError("thumbnail not found", 404);
    return {
      bytes: open(
        { keyId: row.thumbnail_key_id, nonce: buf(row.thumbnail_nonce), ciphertext: buf(row.thumbnail_ciphertext) },
        mediaThumbnailAAD(mediaId),
      ),
      contentType: row.thumbnail_content_type,
    };
  });
}

/** Deletes an abandoned upload immediately. Ready objects are cancellable only before first send. */
export async function cancelMediaUpload(sql: SQL, accountId: string, deviceId: string, mediaId: string) {
  return await sql.begin(async (tx) => {
    await requireActiveMediaAccount(tx, accountId);
    await requireActiveDevice(tx, accountId, deviceId);
    const row = (await tx`
      SELECT owner_account_id, status FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) throw new MediaError("upload not found", 404);
    const referenced = await tx`SELECT 1 FROM messages WHERE media_id = ${mediaId} AND state = 'visible' LIMIT 1`;
    if (referenced.length) throw new MediaError("media is already attached to a message", 409);
    await tx`DELETE FROM media_objects WHERE id = ${mediaId}`;
    return { mediaId, cancelled: true };
  });
}

type ImageDimensions = { width: number; height: number };

function jpegDimensions(bytes: Buffer): ImageDimensions | null {
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  const sof = new Set([0xc0, 0xc1, 0xc2, 0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf]);
  let offset = 2;
  while (offset + 4 <= bytes.length) {
    while (offset < bytes.length && bytes[offset] === 0xff) offset += 1;
    if (offset >= bytes.length) return null;
    const marker = bytes[offset++];
    if (marker === 0xd9 || marker === 0xda) return null;
    if (marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) continue;
    if (offset + 2 > bytes.length) return null;
    const length = bytes.readUInt16BE(offset);
    if (length < 2 || offset + length > bytes.length) return null;
    if (sof.has(marker)) {
      if (length < 7) return null;
      return { height: bytes.readUInt16BE(offset + 3), width: bytes.readUInt16BE(offset + 5) };
    }
    offset += length;
  }
  return null;
}

function pngDimensions(bytes: Buffer): ImageDimensions | null {
  const signature = Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]);
  if (bytes.length < 24 || !bytes.subarray(0, 8).equals(signature) ||
      bytes.readUInt32BE(8) !== 13 || bytes.subarray(12, 16).toString("ascii") !== "IHDR") return null;
  return { width: bytes.readUInt32BE(16), height: bytes.readUInt32BE(20) };
}

function webpDimensions(bytes: Buffer): ImageDimensions | null {
  if (bytes.length < 30 || bytes.subarray(0, 4).toString("ascii") !== "RIFF" ||
      bytes.subarray(8, 12).toString("ascii") !== "WEBP") return null;
  const kind = bytes.subarray(12, 16).toString("ascii");
  if (kind === "VP8X") {
    return {
      width: 1 + bytes.readUIntLE(24, 3),
      height: 1 + bytes.readUIntLE(27, 3),
    };
  }
  if (kind === "VP8 " && bytes.subarray(23, 26).equals(Buffer.from([0x9d, 0x01, 0x2a]))) {
    return { width: bytes.readUInt16LE(26) & 0x3fff, height: bytes.readUInt16LE(28) & 0x3fff };
  }
  if (kind === "VP8L" && bytes[20] === 0x2f) {
    const bits = bytes.readUInt32LE(21);
    return { width: (bits & 0x3fff) + 1, height: ((bits >>> 14) & 0x3fff) + 1 };
  }
  return null;
}

function isoImageDimensions(bytes: Buffer): ImageDimensions | null {
  if (!isISOBaseMedia(bytes)) return null;
  for (let offset = 8; offset + 12 <= bytes.length; offset += 1) {
    if (bytes.subarray(offset, offset + 4).toString("ascii") === "ispe") {
      return { width: bytes.readUInt32BE(offset + 4), height: bytes.readUInt32BE(offset + 8) };
    }
  }
  return null;
}

function validateImage(
  bytes: Buffer, contentType: string, maxDimension: number, maxPixels: number,
): ImageDimensions {
  const normalized = contentType.toLowerCase().split(";", 1)[0];
  const dimensions = normalized === "image/jpeg" ? jpegDimensions(bytes)
    : normalized === "image/png" ? pngDimensions(bytes)
    : normalized === "image/webp" ? webpDimensions(bytes)
    : normalized === "image/heic" || normalized === "image/heif" ? isoImageDimensions(bytes)
    : null;
  if (!dimensions) throw new MediaError(
    "image is truncated, malformed, or unsupported", 415, "invalid_image_content",
  );
  if (dimensions.width <= 0 || dimensions.height <= 0 ||
      dimensions.width > maxDimension || dimensions.height > maxDimension ||
      dimensions.width * dimensions.height > maxPixels) {
    throw new MediaError("image dimensions exceed the limit", 413);
  }
  return dimensions;
}

function isISOBaseMedia(bytes: Buffer): boolean {
  return bytes.length >= 12 && bytes.subarray(4, 8).toString("ascii") === "ftyp";
}

function validateMediaSignature(
  kind: MediaKind, contentType: string, header: Buffer, declaredWidth: unknown, declaredHeight: unknown,
): void {
  if (kind === "file") return;
  if (kind === "photo") {
    const actual = validateImage(header, contentType, MAX_IMAGE_DIMENSION, MAX_IMAGE_PIXELS);
    if (actual.width !== n(declaredWidth) || actual.height !== n(declaredHeight)) {
      throw new MediaError("photo dimensions do not match the upload", 415, "photo_dimensions_mismatch");
    }
    return;
  }
  const webm = header.length >= 4 && header.subarray(0, 4).equals(Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  if (kind === "video" && (isISOBaseMedia(header) || webm)) return;
  const mp3 = header.length >= 3 && (header.subarray(0, 3).toString("ascii") === "ID3" || (header[0] === 0xff && (header[1] & 0xe0) === 0xe0));
  const ogg = header.length >= 4 && header.subarray(0, 4).toString("ascii") === "OggS";
  const wav = header.length >= 12 && header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WAVE";
  if (kind === "voice" && (isISOBaseMedia(header) || mp3 || ogg || wav)) return;
  throw new MediaError("media content does not match its declared type", 415, "media_type_mismatch");
}
