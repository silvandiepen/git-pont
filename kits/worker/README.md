# @git-pont/worker

A Cloudflare Worker that turns [`@git-pont/core`](../core) into a hosted
service: multi-platform OAuth handled server-side, connections persisted so
returning users don't reconnect, and a normalized REST API a web app can call.

Built for **gitKanban**: log in with GitHub OAuth → pick a repo → the worker
serves the data. A returning user with a valid session cookie is recognized
without logging in again.

## How it fits together

- `@git-pont/core` — the auth + proxy library (usable on its own).
- `@git-pont/worker` — **this package**, consumes core and adds sessions,
  persistence, and a per-user profile.

## Endpoints

```
GET   /auth/github/start                         redirect to GitHub consent
GET   /auth/github/callback                       exchange code, set session, redirect to app
GET   /session                                    current session + connections
POST  /logout                                     destroy session
GET   /repositories                               list repos for the session
GET   /repos/:owner/:repo                          repository metadata
GET   /repos/:owner/:repo/branches                 list branches
GET   /repos/:owner/:repo/contents/<path>?ref=b    directory listing or file
GET   /me/profile                                  per-user preferences
PATCH /me/profile                                  update preferences
```

Sessions are carried by a `Secure; HttpOnly; SameSite=Lax` cookie (primary) or
an `Authorization: Bearer <sessionId>` header. Both resolve to the same
server-side record; provider tokens never leave the worker. Credentials are
encrypted at rest (AES-GCM). See
[docs/content/worker-service.md](../../docs/content/worker-service.md).

## Setup

1. **Create a GitHub OAuth App.** Authorization callback URL:
   `https://<your-worker-host>/auth/github/callback`.

2. **Create KV namespaces** and paste the ids into `wrangler.toml`:

   ```sh
   npx wrangler kv:namespace create SESSIONS
   npx wrangler kv:namespace create CONNECTIONS
   npx wrangler kv:namespace create PROFILES
   ```

3. **Set secrets:**

   ```sh
   npx wrangler secret put GITHUB_CLIENT_ID
   npx wrangler secret put GITHUB_CLIENT_SECRET
   # base64-encoded 32 random bytes:
   node -e "console.log(require('crypto').randomBytes(32).toString('base64'))"
   npx wrangler secret put GITPONT_ENC_KEY
   ```

4. **Set vars** in `wrangler.toml`: `ALLOWED_ORIGINS`, `APP_LOGIN_REDIRECT`,
   `OAUTH_REDIRECT_BASE`, `GITHUB_SCOPES`, `SESSION_TTL_SECONDS`.

## Develop

```sh
cp .dev.vars.example .dev.vars   # fill in local secrets
npm run dev                      # wrangler dev (miniflare, local KV)
npm run typecheck
npm run test                     # vitest: crypto + KV store round-trips
```

Quick local checks (no GitHub app needed):

```sh
curl -s localhost:8787/health
curl -s localhost:8787/session            # {"authenticated":false}
curl -si localhost:8787/auth/github/start # 302 to GitHub + state cookie
```

## Deploy

```sh
npm run deploy   # wrangler deploy
```

## gitKanban integration

```js
// Login: full-page navigation
window.location.href = "https://your-worker/auth/github/start";

// After the worker redirects back, call with credentials:
const res = await fetch("https://your-worker/session", { credentials: "include" });
const { authenticated, connections } = await res.json();
```

## Follow-ups

GitLab / Forgejo-Gitea / Bitbucket login and proxying; write endpoints
(commit/PR/submit); a Durable-Object serialized token refresh once GitLab's
short-lived tokens are added.
