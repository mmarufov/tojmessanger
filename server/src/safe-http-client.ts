import { lookup } from "node:dns/promises";
import http from "node:http";
import https from "node:https";
import ipaddr from "ipaddr.js";

const MAX_URL_BYTES = 4_096;
const DEFAULT_CONNECT_TIMEOUT_MS = 5_000;
const DEFAULT_IDLE_TIMEOUT_MS = 3_000;
const DEFAULT_TOTAL_TIMEOUT_MS = 10_000;

export class SafeHTTPError extends Error {
  constructor(message: string, readonly code: string, readonly transient = false) {
    super(message);
    this.name = "SafeHTTPError";
  }
}

export type SafeHTTPResponse = {
  url: URL;
  status: number;
  headers: http.IncomingHttpHeaders;
  body: Buffer;
};

type Address = { address: string; family: 4 | 6 };

function canonicalAddress(value: string): ipaddr.IPv4 | ipaddr.IPv6 {
  const parsed = ipaddr.parse(value);
  return parsed.kind() === "ipv6" && (parsed as ipaddr.IPv6).isIPv4MappedAddress()
    ? (parsed as ipaddr.IPv6).toIPv4Address()
    : parsed;
}

export function isPublicAddress(value: string): boolean {
  try {
    const parsed = ipaddr.parse(value);
    // Reject mapped syntax even when the embedded address is public. It creates too many parser,
    // firewall, and peer-address equivalence edge cases for a preview fetcher.
    if (parsed.kind() === "ipv6" && (parsed as ipaddr.IPv6).isIPv4MappedAddress()) return false;
    return parsed.range() === "unicast";
  } catch {
    return false;
  }
}

export function validatePublicURL(raw: string): URL {
  if (Buffer.byteLength(raw, "utf8") > MAX_URL_BYTES || /[\u0000-\u001f\u007f]/u.test(raw)) {
    throw new SafeHTTPError("URL is invalid", "invalid_url");
  }
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    throw new SafeHTTPError("URL is invalid", "invalid_url");
  }
  if (url.protocol !== "http:" && url.protocol !== "https:") {
    throw new SafeHTTPError("URL scheme is not allowed", "blocked_scheme");
  }
  if (url.username || url.password) {
    throw new SafeHTTPError("URL credentials are not allowed", "blocked_credentials");
  }
  const expectedPort = url.protocol === "https:" ? "443" : "80";
  if (url.port && url.port !== expectedPort) {
    throw new SafeHTTPError("URL port is not allowed", "blocked_port");
  }
  url.hash = "";
  url.hostname = url.hostname.replace(/\.$/, "").toLowerCase();
  if (!url.hostname || url.hostname === "localhost" || url.hostname.endsWith(".localhost")) {
    throw new SafeHTTPError("URL host is not allowed", "blocked_host");
  }
  const literalHost = url.hostname.replace(/^\[/, "").replace(/\]$/, "");
  if (ipaddr.isValid(literalHost) && !isPublicAddress(literalHost)) {
    throw new SafeHTTPError("URL address is not public", "blocked_address");
  }
  return url;
}

async function resolvePublic(hostname: string): Promise<Address[]> {
  if (ipaddr.isValid(hostname)) {
    if (!isPublicAddress(hostname)) {
      throw new SafeHTTPError("URL address is not public", "blocked_address");
    }
    const parsed = ipaddr.parse(hostname);
    return [{ address: parsed.toString(), family: parsed.kind() === "ipv4" ? 4 : 6 }];
  }
  let rows: Array<{ address: string; family: number }>;
  try {
    rows = await lookup(hostname, { all: true, verbatim: true });
  } catch {
    throw new SafeHTTPError("DNS lookup failed", "dns_failure", true);
  }
  if (rows.length === 0 || rows.some((row) => !isPublicAddress(row.address))) {
    throw new SafeHTTPError("URL address is not public", "blocked_address");
  }
  return rows.map((row) => ({ address: row.address, family: row.family === 6 ? 6 : 4 }));
}

function samePeerAddress(actual: string | undefined, expected: string): boolean {
  if (!actual) return false;
  try {
    return canonicalAddress(actual).toNormalizedString()
      === canonicalAddress(expected).toNormalizedString();
  } catch {
    return false;
  }
}

async function oneRequest(
  url: URL,
  options: { maxBytes: number; accept: string; signal?: AbortSignal },
): Promise<SafeHTTPResponse> {
  const addresses = await resolvePublic(url.hostname);
  const selected = addresses[0];
  const transport = url.protocol === "https:" ? https : http;
  return await new Promise<SafeHTTPResponse>((resolve, reject) => {
    let settled = false;
    let total = 0;
    const chunks: Buffer[] = [];
    const fail = (error: Error) => {
      if (settled) return;
      settled = true;
      request.destroy();
      reject(error);
    };
    const totalTimer = setTimeout(
      () => fail(new SafeHTTPError("fetch timed out", "total_timeout", true)),
      DEFAULT_TOTAL_TIMEOUT_MS,
    );
    const request = transport.request(url, {
      method: "GET",
      headers: {
        accept: options.accept,
        "accept-encoding": "identity",
        "user-agent": "TojLinkPreview/1.0",
        connection: "close",
      },
      servername: url.hostname,
      lookup: (_hostname, _lookupOptions, callback) => {
        callback(null, selected.address, selected.family);
      },
    }, (response) => {
      const peer = response.socket.remoteAddress;
      if (!samePeerAddress(peer, selected.address)) {
        clearTimeout(totalTimer);
        fail(new SafeHTTPError("connected peer changed", "peer_mismatch"));
        return;
      }
      const encoding = String(response.headers["content-encoding"] ?? "identity").toLowerCase();
      if (encoding !== "identity") {
        clearTimeout(totalTimer);
        fail(new SafeHTTPError("compressed response is not accepted", "unsupported_encoding"));
        return;
      }
      const declared = Number(response.headers["content-length"] ?? 0);
      if (Number.isFinite(declared) && declared > options.maxBytes) {
        clearTimeout(totalTimer);
        fail(new SafeHTTPError("response is too large", "body_too_large"));
        return;
      }
      response.setTimeout(DEFAULT_IDLE_TIMEOUT_MS, () => {
        fail(new SafeHTTPError("fetch stalled", "idle_timeout", true));
      });
      response.on("data", (chunk: Buffer | Uint8Array) => {
        const buffer = Buffer.from(chunk);
        total += buffer.length;
        if (total > options.maxBytes) {
          fail(new SafeHTTPError("response is too large", "body_too_large"));
          return;
        }
        chunks.push(buffer);
      });
      response.on("end", () => {
        if (settled) return;
        settled = true;
        clearTimeout(totalTimer);
        resolve({
          url,
          status: response.statusCode ?? 0,
          headers: response.headers,
          body: Buffer.concat(chunks, total),
        });
      });
      response.on("error", (error) => {
        clearTimeout(totalTimer);
        fail(new SafeHTTPError(error.message, "response_error", true));
      });
    });
    request.setTimeout(DEFAULT_CONNECT_TIMEOUT_MS, () => {
      fail(new SafeHTTPError("connection timed out", "connect_timeout", true));
    });
    request.on("socket", (socket) => {
      socket.once(url.protocol === "https:" ? "secureConnect" : "connect", () => {
        request.setTimeout(0);
      });
    });
    request.on("error", (error) => {
      clearTimeout(totalTimer);
      fail(new SafeHTTPError(error.message, "connection_error", true));
    });
    if (options.signal) {
      if (options.signal.aborted) {
        clearTimeout(totalTimer);
        fail(new SafeHTTPError("fetch canceled", "canceled", true));
        return;
      }
      options.signal.addEventListener("abort", () => {
        clearTimeout(totalTimer);
        fail(new SafeHTTPError("fetch canceled", "canceled", true));
      }, { once: true });
    }
    request.end();
  });
}

export async function fetchPublicResource(
  rawURL: string,
  options: { maxBytes: number; accept: string; maxRedirects?: number; signal?: AbortSignal },
): Promise<SafeHTTPResponse> {
  let url = validatePublicURL(rawURL);
  const maxRedirects = Math.max(0, Math.min(5, options.maxRedirects ?? 5));
  for (let redirects = 0; redirects <= maxRedirects; redirects += 1) {
    const response = await oneRequest(url, options);
    if (![301, 302, 303, 307, 308].includes(response.status)) return response;
    if (redirects === maxRedirects) {
      throw new SafeHTTPError("redirect limit reached", "redirect_limit");
    }
    const location = response.headers.location;
    if (!location) throw new SafeHTTPError("redirect is missing a location", "invalid_redirect");
    url = validatePublicURL(new URL(location, url).toString());
  }
  throw new SafeHTTPError("redirect limit reached", "redirect_limit");
}
