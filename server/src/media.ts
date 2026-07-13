import type { SQL } from "bun";
import { createHash, randomUUID, timingSafeEqual } from "node:crypto";
import {
  mediaChunkAAD, mediaDigestHMAC, mediaFileNameAAD, mediaThumbnailAAD, open, seal,
} from "./crypto";

export class MediaError extends Error {
  constructor(message: string, readonly status = 400) {
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

const DEFAULT_CHUNK_BYTES = 256 * 1024;
const DEFAULT_MAX_OBJECT_BYTES = 25 * 1024 * 1024;
const DEFAULT_ACCOUNT_QUOTA_BYTES = 250 * 1024 * 1024;
const MAX_THUMBNAIL_BYTES = 256 * 1024;
const SHA256_PATTERN = /^[0-9a-f]{64}$/i;
const CONTENT_TYPE_PATTERN = /^[a-z0-9][a-z0-9!#$&^_.+-]*\/[a-z0-9][a-z0-9!#$&^_.+-]*$/i;
const KINDS = new Set<MediaKind>(["photo", "video", "file", "voice"]);

const n = (value: unknown) => Number(value as any);
const buf = (value: unknown) => Buffer.from(value as Uint8Array);

function boundedEnv(name: string, fallback: number, lower: number, upper: number): number {
  const parsed = Number(process.env[name] ?? fallback);
  return Number.isSafeInteger(parsed) && parsed >= lower && parsed <= upper ? parsed : fallback;
}

export function mediaLimits() {
  return {
    chunkBytes: boundedEnv("TOJ_MEDIA_CHUNK_BYTES", DEFAULT_CHUNK_BYTES, 64 * 1024, 1024 * 1024),
    maxObjectBytes: boundedEnv("TOJ_MEDIA_MAX_OBJECT_BYTES", DEFAULT_MAX_OBJECT_BYTES, 1024, 100 * 1024 * 1024),
    accountQuotaBytes: boundedEnv("TOJ_MEDIA_ACCOUNT_QUOTA_BYTES", DEFAULT_ACCOUNT_QUOTA_BYTES, 1024, 10 * 1024 * 1024 * 1024),
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

export async function createMediaUpload(sql: SQL, accountId: string, input: {
  kind?: unknown; contentType?: unknown; fileName?: unknown; byteSize?: unknown;
  sha256?: unknown; durationMs?: unknown; width?: unknown; height?: unknown;
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
  const { chunkBytes, maxObjectBytes, accountQuotaBytes } = mediaLimits();
  if (!Number.isSafeInteger(byteSize) || byteSize <= 0) throw new MediaError("invalid media size");
  if (byteSize > maxObjectBytes) throw new MediaError("media exceeds the upload limit", 413);
  const sha256 = String(input.sha256 ?? "");
  if (!SHA256_PATTERN.test(sha256)) throw new MediaError("valid SHA-256 required");
  const fileName = cleanFileName(input.fileName);
  const durationMs = optionalPositiveInt(input.durationMs, "duration");
  const width = optionalPositiveInt(input.width, "width");
  const height = optionalPositiveInt(input.height, "height");
  if (width === 0 || height === 0) throw new MediaError("invalid media dimensions");

  return await sql.begin(async (tx) => {
    const owner = await tx`SELECT id FROM accounts WHERE id = ${accountId} AND status IN ('active','limited') FOR UPDATE`;
    if (!owner.length) throw new MediaError("account unavailable", 403);
    const usage = (await tx`
      SELECT COALESCE(sum(byte_size), 0) AS bytes
      FROM media_objects
      WHERE owner_account_id = ${accountId}
        AND status IN ('uploading','ready') AND (status = 'ready' OR expires_at > now())`)[0];
    if (n(usage.bytes) + byteSize > accountQuotaBytes) throw new MediaError("media storage quota exceeded", 413);
    const mediaId = randomUUID();
    const sealedFileName = fileName == null ? null : seal(fileName, mediaFileNameAAD(mediaId));
    const row = (await tx`
      INSERT INTO media_objects
        (id, owner_account_id, kind, content_type, file_name, file_name_key_id,
         file_name_nonce, file_name_ciphertext, byte_size, expected_sha256,
         duration_ms, width, height)
      VALUES (${mediaId}, ${accountId}, ${kind}, ${contentType}, NULL,
              ${sealedFileName?.keyId ?? null}, ${sealedFileName?.nonce ?? null},
              ${sealedFileName?.ciphertext ?? null}, ${byteSize},
              ${mediaDigestHMAC(Buffer.from(sha256, "hex"))}, ${durationMs}, ${width}, ${height})
      RETURNING id, uploaded_bytes, expires_at`)[0];
    return {
      mediaId: row.id,
      uploadOffset: n(row.uploaded_bytes),
      chunkSize: chunkBytes,
      expiresAt: row.expires_at instanceof Date ? row.expires_at.toISOString() : String(row.expires_at),
      quota: { usedBytes: n(usage.bytes) + byteSize, limitBytes: accountQuotaBytes },
    };
  });
}

export async function getMediaUpload(sql: SQL, accountId: string, mediaId: string) {
  const row = (await sql`
    SELECT id, uploaded_bytes, byte_size, status, expires_at
    FROM media_objects WHERE id = ${mediaId} AND owner_account_id = ${accountId}`)[0];
  if (!row) throw new MediaError("upload not found", 404);
  return {
    mediaId: row.id, uploadOffset: n(row.uploaded_bytes), byteSize: n(row.byte_size),
    status: row.status,
    expiresAt: row.expires_at instanceof Date ? row.expires_at.toISOString() : String(row.expires_at),
    chunkSize: mediaLimits().chunkBytes,
  };
}

export async function uploadMediaChunk(
  sql: SQL, accountId: string, mediaId: string, offset: number, bytes: Buffer,
) {
  const { chunkBytes } = mediaLimits();
  if (!Number.isSafeInteger(offset) || offset < 0) throw new MediaError("invalid upload offset");
  if (bytes.length === 0 || bytes.length > chunkBytes) throw new MediaError("invalid media chunk size", 413);
  const digest = mediaDigestHMAC(createHash("sha256").update(bytes).digest());
  return await sql.begin(async (tx) => {
    const row = (await tx`
      SELECT owner_account_id, byte_size, uploaded_bytes, status, expires_at
      FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) throw new MediaError("upload not found", 404);
    if (row.status !== "uploading") throw new MediaError("upload is already complete", 409);
    if (new Date(row.expires_at).getTime() <= Date.now()) throw new MediaError("upload expired", 410);
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
  sql: SQL, accountId: string, mediaId: string, contentType: string, bytes: Buffer,
) {
  if (!/^image\/(jpeg|png|webp)$/i.test(contentType)) throw new MediaError("unsupported thumbnail type");
  if (bytes.length === 0 || bytes.length > MAX_THUMBNAIL_BYTES) throw new MediaError("thumbnail too large", 413);
  if (!validImageSignature(bytes, contentType)) throw new MediaError("thumbnail content does not match its type");
  const sealed = seal(bytes, mediaThumbnailAAD(mediaId));
  const rows = await sql`
    UPDATE media_objects
    SET thumbnail_key_id = ${sealed.keyId}, thumbnail_nonce = ${sealed.nonce},
        thumbnail_ciphertext = ${sealed.ciphertext}, thumbnail_byte_size = ${bytes.length},
        thumbnail_content_type = ${contentType.toLowerCase()}
    WHERE id = ${mediaId} AND owner_account_id = ${accountId} AND status = 'uploading'
    RETURNING id`;
  if (!rows.length) throw new MediaError("upload not found", 404);
  return { mediaId, uploaded: true };
}

export async function completeMediaUpload(sql: SQL, accountId: string, mediaId: string) {
  return await sql.begin(async (tx) => {
    const row = (await tx`
      SELECT owner_account_id, kind, content_type, byte_size, uploaded_bytes, expected_sha256, status, expires_at
      FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) throw new MediaError("upload not found", 404);
    if (row.status === "ready") return { mediaId, ready: true, duplicate: true };
    if (row.status !== "uploading") throw new MediaError("upload unavailable", 409);
    if (new Date(row.expires_at).getTime() <= Date.now()) throw new MediaError("upload expired", 410);
    if (n(row.uploaded_bytes) !== n(row.byte_size)) throw new MediaError("upload is incomplete", 409);
    const chunks = await tx`
      SELECT chunk_offset, plain_size, key_id, nonce, ciphertext
      FROM media_chunks WHERE media_id = ${mediaId} ORDER BY chunk_offset`;
    const hash = createHash("sha256");
    let header = Buffer.alloc(0);
    let expectedOffset = 0;
    for (const chunk of chunks) {
      if (n(chunk.chunk_offset) !== expectedOffset) throw new MediaError("upload has a missing chunk", 409);
      const plaintext = open(
        { keyId: chunk.key_id, nonce: buf(chunk.nonce), ciphertext: buf(chunk.ciphertext) },
        mediaChunkAAD(mediaId, expectedOffset),
      );
      if (plaintext.length !== n(chunk.plain_size)) throw new MediaError("upload chunk is corrupt", 409);
      if (header.length < 64) header = Buffer.concat([header, plaintext.subarray(0, 64 - header.length)]);
      hash.update(plaintext);
      expectedOffset += plaintext.length;
    }
    const digest = mediaDigestHMAC(hash.digest());
    if (expectedOffset !== n(row.byte_size) || !timingSafeEqual(digest, buf(row.expected_sha256))) {
      throw new MediaError("media checksum mismatch", 409);
    }
    validateMediaSignature(row.kind, row.content_type, header);
    await tx`
      UPDATE media_objects SET status = 'ready', completed_at = now(), expires_at = 'infinity'
      WHERE id = ${mediaId}`;
    return { mediaId, ready: true, duplicate: false };
  });
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
    FOR SHARE OF mo`)[0];
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
export async function cancelMediaUpload(sql: SQL, accountId: string, mediaId: string) {
  return await sql.begin(async (tx) => {
    const row = (await tx`
      SELECT owner_account_id, status FROM media_objects WHERE id = ${mediaId} FOR UPDATE`)[0];
    if (!row || row.owner_account_id !== accountId) throw new MediaError("upload not found", 404);
    const referenced = await tx`SELECT 1 FROM messages WHERE media_id = ${mediaId} AND state = 'visible' LIMIT 1`;
    if (referenced.length) throw new MediaError("media is already attached to a message", 409);
    await tx`DELETE FROM media_objects WHERE id = ${mediaId}`;
    return { mediaId, cancelled: true };
  });
}

function validImageSignature(bytes: Buffer, contentType: string): boolean {
  const jpeg = bytes.length >= 3 && bytes[0] === 0xff && bytes[1] === 0xd8 && bytes[2] === 0xff;
  const png = bytes.length >= 8 && bytes.subarray(0, 8).equals(Buffer.from([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]));
  const webp = bytes.length >= 12 && bytes.subarray(0, 4).toString("ascii") === "RIFF" && bytes.subarray(8, 12).toString("ascii") === "WEBP";
  if (contentType === "image/jpeg") return jpeg;
  if (contentType === "image/png") return png;
  if (contentType === "image/webp") return webp;
  return jpeg || png || webp || isISOBaseMedia(bytes);
}

function isISOBaseMedia(bytes: Buffer): boolean {
  return bytes.length >= 12 && bytes.subarray(4, 8).toString("ascii") === "ftyp";
}

function validateMediaSignature(kind: MediaKind, contentType: string, header: Buffer): void {
  if (kind === "file") return;
  if (kind === "photo" && validImageSignature(header, contentType)) return;
  const webm = header.length >= 4 && header.subarray(0, 4).equals(Buffer.from([0x1a, 0x45, 0xdf, 0xa3]));
  if (kind === "video" && (isISOBaseMedia(header) || webm)) return;
  const mp3 = header.length >= 3 && (header.subarray(0, 3).toString("ascii") === "ID3" || (header[0] === 0xff && (header[1] & 0xe0) === 0xe0));
  const ogg = header.length >= 4 && header.subarray(0, 4).toString("ascii") === "OggS";
  const wav = header.length >= 12 && header.subarray(0, 4).toString("ascii") === "RIFF" && header.subarray(8, 12).toString("ascii") === "WAVE";
  if (kind === "voice" && (isISOBaseMedia(header) || mp3 || ogg || wav)) return;
  throw new MediaError("media content does not match its declared type", 415);
}
