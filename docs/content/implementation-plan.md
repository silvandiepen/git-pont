# Implementation Plan

This plan is intended for another implementation agent. Keep commits small and test each layer before adding providers. The canonical API is in [Architecture](architecture.md) and [Provider Model](provider-model.md).

## Phase 0: Platform Contract Hygiene

- Treat the Swift Package as the Swift library, not as the only possible `git-pont` implementation.
- Keep core model names, enum raw values, and error cases portable to Kotlin/TypeScript-style representations.
- Keep provider fixtures JSON-compatible so future kits can reuse them.
- Avoid Apple-only types in `GitPontCore` except where Swift requires a standard-library/Foundation representation such as `URL`, `Data`, or `Date`.

Done when:

- README, Decisions, Architecture, and Provider Model clearly distinguish the shared contract from the Swift library.
- v1 scope still targets Apple only.

## Phase 1: Core

- Create Swift Package for the Swift library.
- Add `GitPontCore`.
- Define all model types from [Provider Model](provider-model.md).
- Define `GitProvider`, `HTTPClient`, `CredentialStore`, `ConnectionStore`, `RetryPolicy`, and `GitPontError`.
- Define `GitAuthenticationProvider`, OAuth start/completion models, and refresh contracts.
- Add `InMemoryCredentialStore`, `InMemoryConnectionStore`, and `FileConnectionStore`.
- Add URL normalization helpers (strip query/fragment/`.git`, hex-ref detection, ambiguity candidate generation).
- Add pagination helper (`Link` header and `x-next-page` follower, safety cap, `GitList`).
- Add the `GitPont` facade skeleton with connection resolution rules.
- Keep Git CLI methods out of the core facade implementation; they are added later by `GitPontGitCLI`.
- Add path safety validation (traversal, absolute paths, control characters, empty message).
- Add test fixture helpers and `MockHTTPClient`.
- Add model, URL parser, pagination, and safety tests.

Done when:

- Package builds.
- Core tests pass.
- No provider modules yet.

## Phase 2: GitHub

- Add `GitPontGitHub`.
- Implement GitHub URL parser (blob, raw, tree, repo, permalink, ambiguous refs).
- Implement account validation (`GET /user`).
- Implement provider construction with explicit instance registration.
- Implement GitHub device-flow start/complete where `OAuthAppConfig` is provided.
- Implement repository list/get with permission mapping, branch list.
- Implement file read (including >1 MB blob fallback), directory list.
- Implement file commit and delete with `sha` conflict protection.
- Implement branch create, repository create, fork create (with readiness polling).
- Implement pull request create (same-repo and fork head).
- Implement mocked HTTP tests for all operations.

Done when:

- GitHub module has full mocked tests.
- GitHub provider supports the Lezin open/commit flow and fork+PR flow.

## Phase 3: GitLab

- Add `GitPontGitLab`.
- Implement GitLab.com preset and self-hosted instance config (including path-prefixed base URLs).
- Implement GitLab URL parser including subgroups, `/-/raw/`, ambiguous refs.
- Implement account, project list/get with permission mapping, branch list.
- Implement provider construction with GitLab.com and explicit self-hosted instance registration.
- Implement Repository Files API read/update/create/delete with `last_commit_id`, plus the follow-up read that populates `newVersion`.
- Implement tree (directory) listing.
- Implement branch create, project create, fork (with `import_status` polling).
- Implement merge request create (same-project and fork with `target_project_id`).
- Add tests for GitLab.com and self-hosted URLs.

Done when:

- GitLab provider supports file open/commit/delete and MR creation including fork MRs.
- Self-hosted URL parsing works without hardcoded host assumptions.

## Phase 4: Forgejo and Gitea

- Add `GitPontForge`.
- Add the Codeberg preset instance (kind `.forgejo`).
- Add custom Forgejo/Gitea instance support.
- Implement provider construction with Codeberg and explicit custom instance registration.
- Implement URL parser for `/src/branch/...`, `/src/commit/...`, `/raw/branch/...`.
- Implement account, repo list/get, branch list.
- Implement file read/write/delete using contents APIs (`sha` required on update/delete).
- Implement directory listing.
- Implement branch create, repository create, fork create.
- Implement pull request creation (same-repo and fork head).
- Add version variance handling: map missing endpoints to `.unsupportedCapability`.

Done when:

- Codeberg preset works in tests.
- Custom Forgejo/Gitea instances are configured explicitly.

## Phase 5: Auth, Refresh, and Keychain

- Add provider-neutral auth abstractions and injected `OAuthAppConfig`.
- Add PAT/token setup support for all providers.
- Add GitHub device flow.
- Add OAuth PKCE for GitLab (access tokens expire in ~2h — refresh is required, not optional) and Forgejo/Gitea where configured.
- Implement `GitAuthenticationProvider.refreshCredential` for OAuth providers and `.unsupportedCapability` for unsupported refresh cases.
- Implement per-connection refresh serialization (actor) with store-before-release semantics.
- Add `GitPontKeychain`.
- Add refresh race tests and Keychain tests where feasible.

Done when:

- Apps can store/reuse connections without handling tokens directly.
- A GitLab OAuth connection survives past token expiry in tests.

## Phase 6: Change Submission

- Implement `submitChange` on the facade: `.directCommit`, `.branchAndPullRequest`, `.forkAndPullRequest`, `.automatic`.
- Implement permission-based strategy selection for `.automatic`.
- Implement fork reuse detection and readiness polling.
- Implement `.partialSubmission` error reporting.
- Add orchestration tests per provider (mocked).

Done when:

- Lezin can save a file it cannot push to, via fork + PR, in a single call.

## Phase 7: Git CLI Credentials

- Add `GitPontGitCLI`.
- Add `GitCLICredentialContext` in `GitPontGitCLI` and expose `gitCredentialContext` through a Swift extension on `GitPont`.
- Resolve credentials for HTTPS remote URLs (normalize, match instance, resolve connection with `preferredConnectionID`).
- Refresh expiring tokens before building the context.
- Return provider-specific credential helper config and environment.
- Add tests that token values never appear in arguments.

Done when:

- GitFolder can replace its GitHub-only token plumbing with GitPont credential context.

## Phase 8: App Integration Guides

- Add small sample integrations for Lezin and GitFolder.
- Document migration from GitFolder `github_token`.
- Document connection setup UI expectations.

## Suggested Commit Split

1. `feat(core): add provider-neutral git-pont models and facade`
2. `feat(github): support file, branch, repo, fork, and pr operations`
3. `feat(gitlab): support cloud and self-hosted instances`
4. `feat(forge): support forgejo, gitea, and codeberg preset`
5. `feat(auth): add credential/connection stores, refresh, and keychain`
6. `feat(core): add change submission orchestration`
7. `feat(cli): add git credential contexts`
8. `test: add provider contract fixtures`
9. `docs: document lezin and gitfolder integrations`
