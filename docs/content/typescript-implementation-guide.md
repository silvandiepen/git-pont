# TypeScript Implementation Guide

This is the runbook for continuing the TypeScript kits (`libs/typescript` →
`@git-pont/core`, `kits/worker` → `@git-pont/worker`). It exists so a new
contributor — human or agent — can pick up the remaining work without
re-deriving context. The GitHub path is complete end to end; the tasks below are
the documented follow-ups.

Read first: [Architecture](architecture.md), [Provider Model](provider-model.md),
[Authentication](authentication.md), [Provider APIs](provider-apis.md),
[TypeScript Core Kit](typescript-kit.md), [Cloudflare Worker Service](worker-service.md).

## Ground rules (do not break these)

- **The Swift kit is canonical.** TypeScript must preserve field names, behavior,
  and error semantics. When in doubt, match `libs/swift`.
- **No secrets in errors or logs.** Error messages must never contain token
  values (see [Security](security.md)).
- **File content is raw bytes** (`Uint8Array`), never a pre-decoded string.
- **Preserve remote version identifiers** (`GitRemoteVersion`) for conflict
  detection on writes.
- **Everything is injected**: HTTP via `HttpClient`, storage via
  `ConnectionStore` / `CredentialStore`. Never call `fetch` or touch KV directly
  from `@git-pont/core`.
- **Tests use a mock `HttpClient`** with fixtures — never hit the network in unit
  tests (mirrors [Testing](testing.md)). Add tests for every new capability.
- Keep `@git-pont/core` free of any Cloudflare/Node-only APIs; it must keep
  running in Workers, Node, and browsers.

## Layout and parity map

| TypeScript | Swift source of truth |
| --- | --- |
| `libs/typescript/src/models.ts` | `GitPontCore/Models.swift` |
| `libs/typescript/src/protocols.ts` | `GitPontCore/Protocols.swift` |
| `libs/typescript/src/errors.ts` | `GitPontCore/Errors.swift` |
| `libs/typescript/src/git-pont.ts` | `GitPontCore/GitPontCore.swift` (facade) |
| `libs/typescript/src/providers/github.ts` | `GitPontGitHub/GitHubProvider.swift` |
| `libs/typescript/src/providers/scaffold.ts` | GitLab/Forge/Bitbucket stubs → port targets below |

The `GitProvider` interface each provider must satisfy is in `protocols.ts`; the
complete, worked example to copy structure from is `providers/github.ts`.

## Dev setup

```sh
npm install                     # from repo root (workspaces)
npm run ts:build                # build @git-pont/core (tsc, strict)
npm run ts:test                 # @git-pont/core unit tests (vitest)
npm run worker:typecheck        # typecheck @git-pont/worker
npm run test --workspace @git-pont/worker   # worker unit tests
npm run worker:dev              # run the worker locally (wrangler dev + .dev.vars)
```

`libs/typescript/test/` shows the mock-client pattern (`test/helpers.ts`).
`kits/worker/test/` shows the KV/crypto pattern (`test/mock-kv.ts`).

## Follow-up tasks

Do them in order; each is independently shippable.

### 1. GitLab provider (`@git-pont/core`)

- **Create** `libs/typescript/src/providers/gitlab.ts` implementing
  `GitProvider` + `GitAuthenticationProvider`. Replace the `GitLabProvider`
  scaffold export in `src/index.ts` / `providers/scaffold.ts`.
- **Port from** `libs/swift/Sources/GitPontGitLab/GitLabProvider.swift`.
- **API notes**: [Provider APIs](provider-apis.md) (GitLab section) — Repository
  Files API needs `api` scope for writes; `x-next-page` pagination; MR wording
  is a UI label only (`changeRequestTerm: "mergeRequest"`).
- **Auth**: OAuth PKCE preferred, PAT fallback. Implement `refreshCredential`
  (GitLab OAuth access tokens expire ~2h and **rotate the refresh token** — a
  duplicate refresh invalidates the winner). The facade already serializes
  refresh per connection; do not add a second refresh path.
- **Support self-hosted**: the constructor already takes an `instances` list;
  use `instance.apiBaseURL` for all requests (never hardcode `gitlab.com`).
- **Acceptance**: [Acceptance Criteria](acceptance-criteria.md) GitLab rows.
  Add unit tests mirroring `test/github.test.ts` (account, repos w/ `x-next-page`
  pagination, read file, commit conflict, OAuth PKCE complete, refresh).

### 2. Forgejo/Gitea provider (`@git-pont/core`)

- **Create** `libs/typescript/src/providers/forge.ts`; port from
  `libs/swift/Sources/GitPontForge/ForgeProvider.swift`.
- **Key detail**: use `Authorization: token <pat>` for PATs and
  `Authorization: Bearer <token>` for OAuth (covered by tests in the Swift kit).
  Codeberg is a preset Forgejo instance, not a separate provider kind.
- **Acceptance**: acceptance-criteria Forgejo/Gitea rows + unit tests.

### 3. Bitbucket provider (`@git-pont/core`)

- **Create** `libs/typescript/src/providers/bitbucket.ts`; port from
  `libs/swift/Sources/GitPontBitbucket/BitbucketProvider.swift`.
- Follow provider-apis.md (Bitbucket section) for pagination and PR shape.
- **Acceptance**: acceptance-criteria Bitbucket rows + unit tests.

### 4. Multi-provider OAuth in the worker (`@git-pont/worker`)

- Today `kits/worker/src/routes/auth.ts` and `src/gitpont.ts` are GitHub-only.
  Generalize: add `:provider` handling so `/auth/:provider/start` and
  `/auth/:provider/callback` work for `github` and `gitlab` (browser/PKCE) and
  `forgejo`/`gitea`/`bitbucket` as configured.
- Add per-provider OAuth config from env (client id/secret/scopes) and register
  the matching provider in `buildUserGitPont`. Keep the state-cookie CSRF check
  and the encrypted-credential storage unchanged.
- A user may now have connections on multiple instances; the session already
  carries `connectionIds` and the API resolves per repo instance. Add a
  `?connectionId=` selector where the caller must disambiguate.
- **Acceptance**: repeat the GitHub smoke test (`/auth/:provider/start` → 302 +
  state cookie; callback persists an encrypted connection; `/session` lists it)
  for GitLab.

### 5. Worker write endpoints (`@git-pont/worker`)

- Add `POST /repos/:owner/:repo/commit`, `POST /repos/:owner/:repo/pulls`, and
  `POST /repos/:owner/:repo/submit` (maps to `GitPont.submitChange`).
- Content comes in as base64 or UTF-8 text; convert to `Uint8Array` before
  building `GitFileChange`. Pass through `expectedVersion` for conflict safety
  and surface `409 conflict` via the existing `statusForCode` map in
  `routes/repos.ts`.
- **Acceptance**: a request that commits a file, and one that opens a PR via the
  `branchAndPullRequest` strategy, against a mock/live repo.

### 6. Serialized GitLab refresh via Durable Object (`@git-pont/worker`)

- The in-process refresh lock in `git-pont.ts` is per-isolate. For GitLab's
  rotating refresh tokens under concurrent Worker isolates, add a Durable Object
  that serializes refresh per connection, and have the worker's credential path
  route refreshes through it. Only needed once GitLab OAuth is live.

### 7. (Optional) Client SDK

- A thin `@git-pont/client` wrapping the worker's REST API with typed methods and
  `credentials: "include"`, so gitKanban imports functions instead of hand-rolled
  fetches.

## Definition of done (per task)

- `npm run ts:build` and `npm run worker:typecheck` pass (strict, no `any`
  leaks).
- New unit tests pass and cover the capability against a mock client.
- `npm run docs:build` still succeeds; update [Provider APIs](provider-apis.md)
  or [TypeScript Core Kit](typescript-kit.md) if behavior/notes changed.
- No secret ever appears in an error, log, or committed file.
- Behavior matches the Swift source and [Acceptance Criteria](acceptance-criteria.md).
