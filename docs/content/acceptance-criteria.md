# Acceptance Criteria

Use this checklist before handing `git-pont` to Lezin or GitFolder.

Items marked "current" are covered by the checked-in Swift package and local validation. Items marked "release" are still required before declaring v1 complete.

## Package

- Current: `swift build` passes from the root public SwiftPM manifest.
- Current: `swift test` passes from the root public SwiftPM manifest.
- Current: `swift build --package-path libs/swift` passes.
- Current: `swift test --package-path libs/swift` passes.
- Current: `npm run docs:build` passes.
- Current: `npm run validate` passes.
- Current: public top-level types have concise documentation comments.
- Current: modules are split so apps can depend on only the providers they need.
- Current: Core has no Apple Keychain dependency.
- Current: Core has no UI framework dependency.
- Current: Core has no dependency on `GitPontGitCLI`; Git CLI support is exposed by importing the Git CLI module.
- Current: public API matches [Architecture](architecture.md) signatures, including provider-neutral OAuth start/complete convenience methods.
- Current: docs distinguish the shared `git-pont` contract from the v1 Apple Swift Package.
- Current: repo uses the monorepo layout documented in the README.
- Current: docs site can be built from `docs/content` through `docs/site/girk.json`.
- Current: core model semantics are portable: no app-specific names, no UI framework types, no Apple-only storage assumptions in `GitPontCore`.
- Current: provider response fixtures use portable JSON/data files for representative read/list contract tests, so future kits can reuse the same shape.

## URL Parsing

- GitHub blob/raw/tree/repo URLs parse, including commit permalinks.
- GitLab blob/raw/repo URLs parse, including subgroups and self-hosted instances.
- Codeberg/Forgejo/Gitea `src/branch`, `src/commit`, and raw URLs parse.
- Query strings, fragments (`#L10`), and trailing `.git` are stripped.
- Slashed branch names produce `.ambiguous` and resolve correctly against the branch list.
- Custom hosts require explicit instance configuration.

## Providers

For each of GitHub, GitLab (cloud + self-hosted), and Forgejo/Gitea (incl. Codeberg preset):

- Account validation loads the current account.
- Repository list (paginated) and repository metadata with permissions work.
- Branch list (paginated) works.
- File read works, including binary files and provider size-limit handling (`.fileTooLarge`, GitHub blob fallback).
- Directory listing works.
- File commit (create and update) works with version conflict protection; `newVersion` is populated.
- File delete works with version conflict protection.
- Branch creation works.
- Current: branch deletion works and is used by opt-in live write cleanup.
- Repository creation works.
- Current: fork creation works.
- Current: fork creation reuses an existing connected-account fork and confirms newly created forks before returning.
- Current: pull/merge request creation works, same-repo and cross-fork.
- Current: file write/delete conflict responses map to `.conflict` with populated `GitConflict`.

## Change Submission

- Current: `.directCommit`, `.branchAndPullRequest`, `.forkAndPullRequest` work through the provider-neutral facade.
- Current: `.automatic` selects direct commit, branch + PR, or fork + PR from repository permissions and branch protection.
- Current: partial failures return `.partialSubmission` with enough context to retry only the missing step.

## Auth

- Current: connections store metadata only; persistence goes through `ConnectionStore`.
- Current: credentials are stored through `CredentialStore`.
- Current: in-memory stores exist for tests; `FileConnectionStore` exists for apps.
- Current: Apple Keychain credential storage exists in `GitPontKeychain`.
- Current: PAT/token setup works for all providers.
- Current: OAuth start/complete models exist in core.
- Current: GitHub device flow works with an injected client ID.
- Current: GitLab OAuth PKCE works, and automatic refresh keeps a connection alive past the approximate two-hour token expiry.
- Current: Forgejo/Gitea browser OAuth works for configured instances.
- Current: refresh is serialized per connection and persisted before dependent requests proceed.
- Current: provider refresh hooks are covered by tests.
- Current: reactive refresh-and-retry after an unexpected provider authentication failure is implemented and tested.
- Current: multiple accounts on one instance resolve via `preferredConnectionID` / `.ambiguousConnection`.
- Current: OAuth code is isolated so apps can choose whether to use it.

## Git CLI

- Current: HTTPS remote credential context works for GitHub, GitLab.com, self-hosted GitLab, and Codeberg/Forgejo/Gitea.
- Current: the credential context API is available only when importing `GitPontGitCLI`.
- Current: tokens do not appear in command arguments.
- Current: `GIT_TERMINAL_PROMPT=0` is set.
- Current: expiring tokens are refreshed before the context is built.

## Tests

- Current: URL parser matrix covers the provider forms in the mocked tests, including ambiguity.
- Current: request construction tests exist for provider write endpoints.
- Current: response decoding tests exist for provider read endpoints.
- Current: pagination tests exist for provider list endpoints.
- Current: conflict mapping tests exist for provider file write/delete endpoints.
- Current: change submission tests exist for direct, branch + PR, fork + PR, and automatic selection.
- Current: change submission tests cover partial failures.
- Current: credential and connection store tests exist.
- Current: refresh race tests exist.
- Current: Git CLI credential tests exist.
- Current: safety tests exist for path traversal, token exposure, delete-without-version, empty commit messages, provider file size limits, delete-is-explicit behavior, and blind-overwrite create/update protection.
- Current: no default test hits the network.
- Current: live account smoke tests are opt-in through environment variables only.
- Current: opt-in live write tests cover disposable branch/file create/read/delete operations and branch cleanup when dedicated test repositories are configured.
- Release: run the opt-in live write tests against dedicated GitHub, GitLab, and Forgejo/Gitea repositories before tagging v1.

## App Readiness

- Lezin can open a remote file from URL.
- Lezin can save by committing without local Git.
- Lezin can propose a change to a repo it cannot push to (fork + PR) in one call.
- Lezin can check staleness via `checkForRemoteChange`.
- GitFolder can resolve provider credentials for `git pull` and `git push`.
- GitFolder can list repositories and branches, and create a new remote repository during folder setup.
- Existing GitFolder GitHub token migration path is documented.
