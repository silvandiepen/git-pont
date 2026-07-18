/** OAuth login/callback, session inspection, and logout. */

import type { GitConnection } from "@git-pont/core";
import { isGitPontError } from "@git-pont/core";
import type { Env } from "../env.js";
import {
  buildAnonymousGitPont,
  buildUserGitPont,
  githubAccount,
  githubInstance,
  githubOAuthConfig,
  githubUserId,
} from "../gitpont.js";
import { errorResponse, json, redirect, serializeCookie, clearCookie, parseCookies } from "../http.js";
import {
  OAUTH_STATE_COOKIE,
  clearedSessionCookieHeader,
  resolveSession,
  sessionCookieHeader,
  sessionStore,
} from "../session.js";

/** GET /auth/github/start — redirect the browser to GitHub's consent screen. */
export async function startGitHubLogin(request: Request, env: Env): Promise<Response> {
  const gitPont = buildAnonymousGitPont(env);
  const start = await gitPont.startOAuth({
    instance: githubInstance,
    method: "oauthPKCE",
    appConfig: githubOAuthConfig(env),
  });
  if (start.kind !== "browser") {
    return errorResponse(500, "Expected a browser OAuth session for GitHub");
  }
  const stateCookie = serializeCookie(OAUTH_STATE_COOKIE, start.state, {
    httpOnly: true,
    secure: true,
    sameSite: "Lax",
    path: "/",
    maxAge: 600,
  });
  return redirect(start.authorizationURL, { "Set-Cookie": stateCookie });
}

/** GET /auth/github/callback — exchange the code, persist the connection, start a session. */
export async function gitHubCallback(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const queryState = url.searchParams.get("state");
  const cookieState = parseCookies(request)[OAUTH_STATE_COOKIE];
  if (!queryState || !cookieState || queryState !== cookieState) {
    return errorResponse(400, "Invalid or missing OAuth state", "invalid_state");
  }
  if (url.searchParams.get("error")) {
    return errorResponse(400, url.searchParams.get("error_description") ?? "OAuth denied", "oauth_denied");
  }

  const anon = buildAnonymousGitPont(env);
  let credential;
  try {
    credential = await anon.completeOAuth({
      instance: githubInstance,
      method: "oauthPKCE",
      appConfig: githubOAuthConfig(env),
      callbackURL: request.url,
      state: queryState,
    });
  } catch (error) {
    return oauthError(error);
  }

  const account = await githubAccount(env, credential);
  const userId = githubUserId(account);
  const { gitPont, connectionStore, credentialStore } = buildUserGitPont(env, userId);

  // Reuse an existing connection for this account (returning user) so the
  // stored connection id and any per-connection data stay stable.
  const existing = (await connectionStore.connections()).find(
    (c) => c.instance.id === githubInstance.id && c.accountID === account.id,
  );

  let connection: GitConnection;
  if (existing) {
    connection = { ...existing, updatedAt: new Date() };
    await connectionStore.save(connection);
    await credentialStore.save(credential, connection.id);
  } else {
    connection = await gitPont.addConnection(githubInstance, credential, "oauthPKCE");
  }

  const sessionId = await sessionStore(env).create(userId, [connection.id]);

  const headers = new Headers();
  headers.append("Set-Cookie", sessionCookieHeader(env, sessionId));
  headers.append(
    "Set-Cookie",
    clearCookie(OAUTH_STATE_COOKIE, { httpOnly: true, secure: true, sameSite: "Lax", path: "/" }),
  );
  headers.set("Location", env.APP_LOGIN_REDIRECT);
  return new Response(null, { status: 302, headers });
}

/** GET /session — the returning-user check: current session + connections. */
export async function getSession(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (!session) return json({ authenticated: false }, { status: 200 });

  const { connectionStore } = buildUserGitPont(env, session.record.userId);
  const connections = await connectionStore.connections();
  return json({
    authenticated: true,
    userId: session.record.userId,
    expiresAt: session.record.expiresAt,
    connections: connections.map(publicConnection),
  });
}

/** POST /logout — destroy the session and clear the cookie. */
export async function logout(request: Request, env: Env): Promise<Response> {
  const session = await resolveSession(request, env);
  if (session) await sessionStore(env).destroy(session.sessionId);
  return json({ ok: true }, { headers: { "Set-Cookie": clearedSessionCookieHeader() } });
}

function publicConnection(connection: GitConnection) {
  return {
    id: connection.id,
    provider: connection.instance.kind,
    instanceId: connection.instance.id,
    accountLogin: connection.accountLogin,
    displayName: connection.displayName,
    authMethod: connection.authMethod,
  };
}

function oauthError(error: unknown): Response {
  if (isGitPontError(error)) {
    return errorResponse(401, error.message, error.code);
  }
  return errorResponse(500, "OAuth completion failed");
}
