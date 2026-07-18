/**
 * git-pont Cloudflare Worker.
 *
 * Exposes multi-platform OAuth, sessions, and a normalized REST proxy built on
 * `@git-pont/core`, so a web app (e.g. gitKanban) can log in with GitHub OAuth,
 * pick a repo, and read repository data — and return later, with a valid
 * session cookie, without reconnecting.
 *
 * Routes:
 *   GET  /auth/github/start        -> redirect to GitHub consent
 *   GET  /auth/github/callback     -> exchange code, persist connection, set session
 *   GET  /session                  -> current session + connections
 *   POST /logout                   -> destroy session
 *   GET  /repositories             -> list repos for the session's connection
 *   GET  /repos/:owner/:repo       -> repository metadata
 *   GET  /repos/:owner/:repo/branches
 *   GET  /repos/:owner/:repo/contents/<path>?ref=branch
 *   GET  /me/profile               -> per-user preferences
 *   PATCH /me/profile              -> update preferences
 */

import type { Env } from "./env.js";
import { preflight, withCors } from "./cors.js";
import { errorResponse, json } from "./http.js";
import { resolveSession, type ResolvedSession } from "./session.js";
import { getSession, gitHubCallback, logout, startGitHubLogin } from "./routes/auth.js";
import {
  getContents,
  getRepository,
  listBranches,
  listRepositories,
} from "./routes/repos.js";
import { getProfile, patchProfile } from "./routes/profile.js";

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    if (request.method === "OPTIONS") return preflight(request, env);
    try {
      const response = await route(request, env);
      return withCors(response, request, env);
    } catch (error) {
      const message = error instanceof Error ? error.message : "Internal error";
      return withCors(errorResponse(500, message), request, env);
    }
  },
};

async function route(request: Request, env: Env): Promise<Response> {
  const url = new URL(request.url);
  const method = request.method.toUpperCase();
  const segments = url.pathname.split("/").filter((s) => s.length > 0);

  // --- Public routes (no session required) ---
  if (method === "GET" && matches(segments, ["auth", "github", "start"])) {
    return startGitHubLogin(request, env);
  }
  if (method === "GET" && matches(segments, ["auth", "github", "callback"])) {
    return gitHubCallback(request, env);
  }
  if (method === "GET" && matches(segments, ["session"])) {
    return getSession(request, env);
  }
  if (method === "POST" && matches(segments, ["logout"])) {
    return logout(request, env);
  }
  if (method === "GET" && matches(segments, ["health"])) {
    return json({ ok: true });
  }

  // --- Authenticated routes ---
  const session = await resolveSession(request, env);
  if (!session) return errorResponse(401, "Not authenticated", "authenticationRequired");

  if (method === "GET" && matches(segments, ["repositories"])) {
    return listRepositories(env, session);
  }
  if (method === "GET" && matches(segments, ["me", "profile"])) {
    return getProfile(env, session);
  }
  if (method === "PATCH" && matches(segments, ["me", "profile"])) {
    return patchProfile(request, env, session);
  }

  // /repos/:owner/:repo[...]
  if (segments[0] === "repos" && segments.length >= 3) {
    return routeRepos(request, env, session, segments, method, url);
  }

  return errorResponse(404, "Not found");
}

function routeRepos(
  request: Request,
  env: Env,
  session: ResolvedSession,
  segments: string[],
  method: string,
  url: URL,
): Promise<Response> {
  const owner = decodeURIComponent(segments[1]!);
  const repo = decodeURIComponent(segments[2]!);
  const rest = segments.slice(3);

  if (method === "GET" && rest.length === 0) {
    return getRepository(env, session, owner, repo);
  }
  if (method === "GET" && rest.length === 1 && rest[0] === "branches") {
    return listBranches(env, session, owner, repo);
  }
  if (method === "GET" && rest[0] === "contents") {
    const path = rest
      .slice(1)
      .map((s) => decodeURIComponent(s))
      .join("/");
    return getContents(env, session, owner, repo, path, url.searchParams.get("ref"));
  }
  return Promise.resolve(errorResponse(404, "Not found"));
}

function matches(segments: string[], pattern: string[]): boolean {
  if (segments.length !== pattern.length) return false;
  return pattern.every((part, index) => segments[index] === part);
}
