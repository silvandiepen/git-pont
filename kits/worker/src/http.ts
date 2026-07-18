/** Small HTTP helpers: JSON responses, redirects, and cookie parsing. */

export function json(data: unknown, init: ResponseInit = {}): Response {
  return new Response(JSON.stringify(data), {
    ...init,
    headers: { "Content-Type": "application/json; charset=utf-8", ...(init.headers ?? {}) },
  });
}

export function errorResponse(status: number, message: string, code?: string): Response {
  return json({ error: message, code }, { status });
}

export function redirect(location: string, headers: Record<string, string> = {}): Response {
  return new Response(null, { status: 302, headers: { Location: location, ...headers } });
}

export function parseCookies(request: Request): Record<string, string> {
  const header = request.headers.get("Cookie");
  if (!header) return {};
  const cookies: Record<string, string> = {};
  for (const part of header.split(";")) {
    const index = part.indexOf("=");
    if (index === -1) continue;
    const name = part.slice(0, index).trim();
    const value = part.slice(index + 1).trim();
    if (name) cookies[name] = decodeURIComponent(value);
  }
  return cookies;
}

export interface CookieOptions {
  maxAge?: number;
  path?: string;
  httpOnly?: boolean;
  secure?: boolean;
  sameSite?: "Strict" | "Lax" | "None";
}

export function serializeCookie(name: string, value: string, options: CookieOptions = {}): string {
  const segments = [`${name}=${encodeURIComponent(value)}`];
  segments.push(`Path=${options.path ?? "/"}`);
  if (options.maxAge !== undefined) segments.push(`Max-Age=${Math.floor(options.maxAge)}`);
  if (options.httpOnly ?? true) segments.push("HttpOnly");
  if (options.secure ?? true) segments.push("Secure");
  segments.push(`SameSite=${options.sameSite ?? "Lax"}`);
  return segments.join("; ");
}

/** A cleared cookie (Max-Age=0). */
export function clearCookie(name: string, options: CookieOptions = {}): string {
  return serializeCookie(name, "", { ...options, maxAge: 0 });
}
