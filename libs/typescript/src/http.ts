/**
 * Minimal HTTP transport abstraction, so provider modules stay testable
 * without the network. Mirrors the Swift `HTTPClient`/`HTTPRequest`/
 * `HTTPResponse` types and the default `RetryPolicy`.
 */

export interface HttpRequest {
  method: string;
  url: string;
  headers?: Record<string, string>;
  body?: Uint8Array | string;
}

export class HttpResponse {
  readonly statusCode: number;
  readonly headers: Record<string, string>;
  readonly body: Uint8Array;

  constructor(statusCode: number, headers: Record<string, string> = {}, body: Uint8Array = new Uint8Array()) {
    this.statusCode = statusCode;
    this.headers = headers;
    this.body = body;
  }

  /** Case-insensitive header lookup. */
  header(name: string): string | undefined {
    const lower = name.toLowerCase();
    for (const key of Object.keys(this.headers)) {
      if (key.toLowerCase() === lower) return this.headers[key];
    }
    return undefined;
  }

  text(): string {
    return new TextDecoder().decode(this.body);
  }

  json<T>(): T {
    return JSON.parse(this.text()) as T;
  }
}

export interface HttpClient {
  send(request: HttpRequest): Promise<HttpResponse>;
}

/** `fetch`-backed HTTP client. Works in Workers, Node 18+, and browsers. */
export class FetchHttpClient implements HttpClient {
  private readonly fetchImpl: typeof fetch;

  constructor(fetchImpl: typeof fetch = fetch) {
    this.fetchImpl = fetchImpl;
  }

  async send(request: HttpRequest): Promise<HttpResponse> {
    const init: RequestInit = { method: request.method, headers: request.headers };
    if (request.body !== undefined) {
      init.body = typeof request.body === "string" ? request.body : new Uint8Array(request.body);
    }
    const response = await this.fetchImpl(request.url, init);
    const buffer = new Uint8Array(await response.arrayBuffer());
    const headers: Record<string, string> = {};
    response.headers.forEach((value, key) => {
      headers[key] = value;
    });
    return new HttpResponse(response.status, headers, buffer);
  }
}

export interface RetryPolicy {
  maxRetries: number;
  /** Sleep in milliseconds; injectable so tests run with zero delay. */
  sleep: (ms: number) => Promise<void>;
}

export function defaultRetryPolicy(): RetryPolicy {
  return {
    maxRetries: 3,
    sleep: (ms) => new Promise((resolve) => setTimeout(resolve, ms)),
  };
}

const IDEMPOTENT_METHODS = new Set(["GET", "HEAD", "OPTIONS"]);

/**
 * Send with the default retry policy: retry idempotent reads on 429/5xx,
 * honoring `Retry-After` when present, otherwise exponential backoff with
 * jitter. Writes are never retried automatically.
 */
export async function sendWithRetry(
  client: HttpClient,
  request: HttpRequest,
  policy: RetryPolicy,
  random: () => number = Math.random,
): Promise<HttpResponse> {
  const method = request.method.toUpperCase();
  if (!IDEMPOTENT_METHODS.has(method)) {
    return client.send(request);
  }

  let attempt = 0;
  // eslint-disable-next-line no-constant-condition
  while (true) {
    const response = await client.send(request);
    const retryable = response.statusCode === 429 || (response.statusCode >= 500 && response.statusCode < 600);
    if (!retryable || attempt >= policy.maxRetries) {
      return response;
    }
    const retryAfter = parseRetryAfter(response.header("Retry-After"));
    const backoff = retryAfter ?? 2 ** attempt * 1000 + Math.floor(random() * 250);
    await policy.sleep(backoff);
    attempt += 1;
  }
}

function parseRetryAfter(value: string | undefined): number | undefined {
  if (!value) return undefined;
  const seconds = Number(value);
  if (!Number.isNaN(seconds)) return seconds * 1000;
  const date = Date.parse(value);
  if (!Number.isNaN(date)) return Math.max(0, date - Date.now());
  return undefined;
}

/** Portable base64 encode of raw bytes (Workers, Node, browser). */
export function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** Portable base64 decode to raw bytes (Workers, Node, browser). */
export function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64.replace(/\s/g, ""));
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) {
    bytes[i] = binary.charCodeAt(i);
  }
  return bytes;
}

export function utf8ToBytes(text: string): Uint8Array {
  return new TextEncoder().encode(text);
}

export function bytesToUtf8(bytes: Uint8Array): string {
  return new TextDecoder().decode(bytes);
}

/** Encode a record as `application/x-www-form-urlencoded`, sorted by key. */
export function formEncode(fields: Record<string, string>): string {
  return Object.keys(fields)
    .sort()
    .map((key) => `${encodeURIComponent(key)}=${encodeURIComponent(fields[key] ?? "")}`)
    .join("&");
}

/** Append query items to a URL string. */
export function appendQuery(url: string, params: Record<string, string>): string {
  const parsed = new URL(url);
  for (const [key, value] of Object.entries(params)) {
    parsed.searchParams.append(key, value);
  }
  return parsed.toString();
}

/** Follow a GitHub/Forgejo/Gitea `Link: ...; rel="next"` header. */
export function nextLinkURL(response: HttpResponse): string | undefined {
  const link = response.header("Link");
  if (!link) return undefined;
  for (const part of link.split(",")) {
    const sections = part.split(";").map((s) => s.trim());
    if (sections.includes('rel="next"') && sections[0]) {
      return sections[0].replace(/^<|>$/g, "");
    }
  }
  return undefined;
}
