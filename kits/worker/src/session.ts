/**
 * Session resolution. Accepts the session id from either the HttpOnly cookie
 * (primary path for gitKanban) or an `Authorization: Bearer <sessionId>` header
 * (native / cross-origin callers). Both resolve to the same server-side record;
 * provider tokens never leave the worker in either path.
 */

import { sessionTTLSeconds, type Env } from "./env.js";
import { parseCookies, serializeCookie, clearCookie, type CookieOptions } from "./http.js";
import { SessionStore, type SessionRecord } from "./stores/session-store.js";

export const SESSION_COOKIE = "gitpont_session";
export const OAUTH_STATE_COOKIE = "gitpont_oauth_state";

export function sessionStore(env: Env): SessionStore {
  return new SessionStore(env.SESSIONS, sessionTTLSeconds(env));
}

/** Extract the session id from the cookie or the Authorization bearer header. */
export function extractSessionId(request: Request): string | undefined {
  const cookies = parseCookies(request);
  const cookieValue = cookies[SESSION_COOKIE];
  if (cookieValue) return cookieValue;
  const auth = request.headers.get("Authorization");
  if (auth && auth.startsWith("Bearer ")) return auth.slice("Bearer ".length).trim();
  return undefined;
}

export interface ResolvedSession {
  sessionId: string;
  record: SessionRecord;
}

export async function resolveSession(
  request: Request,
  env: Env,
): Promise<ResolvedSession | undefined> {
  const sessionId = extractSessionId(request);
  if (!sessionId) return undefined;
  const record = await sessionStore(env).get(sessionId);
  if (!record) return undefined;
  return { sessionId, record };
}

function baseCookieOptions(env: Env): CookieOptions {
  return {
    httpOnly: true,
    secure: true,
    sameSite: "Lax",
    path: "/",
    maxAge: sessionTTLSeconds(env),
  };
}

export function sessionCookieHeader(env: Env, sessionId: string): string {
  return serializeCookie(SESSION_COOKIE, sessionId, baseCookieOptions(env));
}

export function clearedSessionCookieHeader(): string {
  return clearCookie(SESSION_COOKIE, { httpOnly: true, secure: true, sameSite: "Lax", path: "/" });
}
