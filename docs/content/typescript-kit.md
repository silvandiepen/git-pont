# TypeScript Core Kit

`@git-pont/core` (`libs/typescript`) is a TypeScript port of the canonical
git-pont contract. It is the **auth + REST proxy** layer: the same provider-neutral
concepts as the Swift library — connection, repository, branch, file reference,
commit, pull request — expressed as TypeScript types and a `GitPont` facade.

It is framework-agnostic. It depends only on the global `fetch` and WebCrypto,
so it runs unchanged in Cloudflare Workers, Node 18+, and browsers. The
Cloudflare Worker kit (`kits/worker`, `@git-pont/worker`) consumes this package
and adds sessions and persistence; you can also use `@git-pont/core` on its own.

## Contract parity

The types mirror `libs/swift/Sources/GitPontCore/Models.swift` and
`Protocols.swift` field-for-field. Swift enums with associated values become
discriminated unions:

```ts
type GitRemoteVersion =
  | { kind: "blobSHA"; sha: string }
  | { kind: "commitID"; id: string }
  | { kind: "opaque"; provider: GitProviderKind; value: string };
```

File content is raw bytes (`Uint8Array`), never a decoded string, matching the
Swift `Data` contract. Errors are a single `GitPontError` class with a
discriminated `code` and optional payload; messages never contain token values.

## Facade

```ts
import {
  GitPont,
  GitHubProvider,
  FetchHttpClient,
  InMemoryConnectionStore,
  InMemoryCredentialStore,
} from "@git-pont/core";

const gitPont = new GitPont({
  providers: [new GitHubProvider(new FetchHttpClient(), githubOAuthConfig)],
  connectionStore: new InMemoryConnectionStore(),
  credentialStore: new InMemoryCredentialStore(),
});

const parsed = gitPont.parse("https://github.com/owner/repo/blob/feature/x/doc.md");
const reference = await gitPont.resolve(parsed); // disambiguates slashed branches
const file = await gitPont.openFile("https://github.com/owner/repo");
const repos = await gitPont.repositories(connectionId);
```

The facade owns provider/connection resolution, proactive and race-free token
refresh (serialized per connection — the JS analog of the Swift refresh actor),
retry policy, two-phase URL parsing, and the change-submission strategies
(`directCommit`, `existingBranch`, `branchAndPullRequest`, `forkAndPullRequest`,
`automatic`).

## Providers

- **GitHub** — complete: OAuth device flow, OAuth authorization-code (web) flow
  for backend-mediated consumers, and PAT; account, repositories, repository,
  branches, read file, list directory, commit, delete, create branch, create
  repository, fork, and create pull request.
- **GitLab / Forgejo-Gitea / Bitbucket** — scaffolded. They declare identity,
  capabilities, and host routing (`canHandle`) so the registry works, and throw
  `unsupportedCapability` for operations until ported from the Swift kit.

## Storage abstractions

`CredentialStore` and `ConnectionStore` are the same async protocols as the
Swift kit. `@git-pont/core` ships in-memory implementations for tests; the
worker kit provides Cloudflare KV-backed implementations with encrypted
credentials.

## Tests

Vitest specs cover URL parsing (including ambiguous slashed branches),
connection resolution, serialized token refresh, and the GitHub provider against
a mock `HttpClient` — no network access, mirroring the Swift unit-test approach.

```sh
npm run ts:build   # tsc, strict
npm run ts:test    # vitest
```
