# Cloudflare Worker Service

`@git-pont/worker` (`kits/worker`) is a deployable Cloudflare Worker that turns
`@git-pont/core` into a hosted service. It handles multi-platform authentication
server-side, persists connections so returning users do not reconnect, and
exposes a normalized REST API a web app can call.

The first consumer is **gitKanban**: a user logs in with GitHub OAuth, picks a
repository, and the worker serves repository data. With a valid session cookie,
a returning user is recognized without logging in again.

Relationship to the core kit: the worker **consumes** `@git-pont/core`. The
core kit (auth + proxy) is usable standalone; the worker adds the stateful
concerns (OAuth callback handling, sessions, persistence, per-user profile).

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/auth/github/start` | Redirect the browser to GitHub's consent screen (sets a short-lived state cookie). |
| GET | `/auth/github/callback` | Exchange the code, persist/reuse the connection, create a session, redirect to the app. |
| GET | `/session` | Current session and connections. The returning-user check. |
| POST | `/logout` | Destroy the session and clear the cookie. |
| GET | `/repositories` | List repositories for the session's connection. |
| GET | `/repos/:owner/:repo` | Repository metadata (also records a recent repo). |
| GET | `/repos/:owner/:repo/branches` | List branches. |
| GET | `/repos/:owner/:repo/contents/<path>?ref=branch` | Directory listing or single file (UTF-8 text when decodable, plus base64). |
| GET | `/me/profile` | Per-user preferences (color mode, recent repos, app preferences). |
| PATCH | `/me/profile` | Shallow-merge preference updates. |

## Sessions — cookie or bearer, one server-side record

On a successful OAuth callback the worker mints an opaque, unguessable session
id and stores it server-side (KV). The id is returned as a `Secure; HttpOnly;
SameSite=Lax` cookie — the primary path for a web app calling with
`credentials: "include"`. The same id may also be sent as
`Authorization: Bearer <sessionId>` for native or cross-origin callers. Both
resolve to the same session record; **provider access and refresh tokens never
leave the worker** in either path.

Session lifetime is configurable (`SESSION_TTL_SECONDS`, default 30 days). While
the cookie is valid, `/session` returns the connection without re-authenticating
— this is the "don't reconnect" behavior.

## Storage — Cloudflare KV

Three KV namespaces, all keyed so a user only ever sees their own data:

- `SESSIONS` — `session:<id>` → `{ userId, connectionIds, expiresAt }`.
- `CONNECTIONS` — `conn:<userId>:<connId>` (metadata, no secrets) and
  `cred:<userId>:<connId>` (credentials **encrypted at rest** with AES-GCM using
  the `GITPONT_ENC_KEY` secret).
- `PROFILES` — `profile:<userId>` → color mode, recent repos, app preferences.

The stores implement the core `ConnectionStore` / `CredentialStore` interfaces,
scoped per user, so the facade never observes cross-user data. KV was chosen for
simplicity; because storage sits behind interfaces, D1 (for relational queries)
or a Durable Object (for strictly serialized GitLab token refresh) can be
swapped in later without touching the facade.

## Configuration

Vars (`wrangler.toml`): `ALLOWED_ORIGINS`, `APP_LOGIN_REDIRECT`,
`OAUTH_REDIRECT_BASE`, `GITHUB_SCOPES`, `SESSION_TTL_SECONDS`.

Secrets (`wrangler secret put` / `.dev.vars`): `GITHUB_CLIENT_ID`,
`GITHUB_CLIENT_SECRET`, `GITPONT_ENC_KEY` (base64-encoded 32-byte key).

CORS is locked to `ALLOWED_ORIGINS` with credentials enabled.

## gitKanban integration

1. Send the user to `GET /auth/github/start` (full-page navigation).
2. After consent GitHub returns to `/auth/github/callback`; the worker sets the
   session cookie and redirects to `APP_LOGIN_REDIRECT`.
3. Call the API with `credentials: "include"`. On load, call `GET /session`; if
   `authenticated` is true, skip the login prompt.
4. Store UI preferences via `PATCH /me/profile`.

## Follow-ups

- GitLab / Forgejo-Gitea / Bitbucket login and proxying (GitLab's ~2h tokens
  introduce a Durable-Object serialized refresh).
- Write endpoints (`commit`, `pulls`, `submit`) once the app needs writes.
- An optional thin client SDK for calling the worker.
