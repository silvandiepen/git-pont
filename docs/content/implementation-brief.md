# Implementation Brief

Build the v1 Swift library for `git-pont` as a standalone Swift Package that lets apps connect to Git hosting platforms, read and write repository files, create branches/repositories/forks, create PRs/MRs (including cross-fork), submit changes end-to-end, and provide HTTPS credentials for system Git commands.

The canonical API surface is defined in [Architecture](architecture.md); all model types are defined in [Provider Model](provider-model.md). Where any doc disagrees with those two, those two win.

`git-pont` is intended to support other platform kits later. The Swift Package is the first implementation, not a statement that the provider model is Swift-only. See [Kits and Platforms](kits-and-platforms.md).

## Product Decisions

- Bitbucket Cloud is included in v1. Bitbucket Server/Data Center is not included.
- No SSH in the main integration model. Platform account connections over HTTPS are the default path.
- Codeberg is a preset Forgejo instance, not a separate provider kind.
- Apple/Swift is the only v1 implementation target.
- Android, web, and backend kits are future work, but v1 API/model decisions must remain portable.
- Language, OAuth ownership, and naming decisions are recorded in [Decisions](decisions.md).

Supported v1 platforms:

- GitHub
- GitLab.com
- Self-hosted GitLab
- Codeberg (Forgejo preset)
- Forgejo custom instances
- Gitea custom instances

## Definition of Done for v1

The Swift library is ready for app integration when:

- It builds as a Swift Package.
- Public API is documented enough for Lezin and GitFolder to consume.
- GitHub file read/write/delete, branch/repo/fork creation, and PR creation are implemented with mocked tests.
- GitLab.com and self-hosted GitLab file read/write/delete, branch/repo/fork creation, and MR creation are implemented with mocked tests.
- Codeberg/Forgejo/Gitea and Bitbucket Cloud file read/write/delete, branch/repo/fork creation, and PR creation are implemented with mocked tests.
- `submitChange` works for direct commit, branch + PR, fork + PR, and automatic strategy selection on all providers.
- Provider URL parsing is covered by a fixture matrix, including slashed-branch ambiguity and permalinks.
- Pagination is followed on all list endpoints with the documented safety cap.
- Credentials are stored only through `CredentialStore`; connections only through `ConnectionStore`.
- Apple Keychain credential store exists in a separate module.
- Provider constructors explicitly register public and self-hosted instances; custom hosts are never guessed.
- OAuth start/complete and token refresh APIs are implemented through provider-neutral auth models.
- Token refresh is automatic, race-free, and persisted (GitLab OAuth depends on it).
- Git CLI credential context exists for HTTPS remotes in `GitPontGitCLI`, exposed as a Swift extension on `GitPont`.
- No token is ever stored in repository config models or remote URLs.
- All network behavior is testable through an injected HTTP client.
- No default tests require live network access.

## Current Build Status

The repository is buildable now:

- Swift package build passes from the root public SwiftPM manifest and from `libs/swift`.
- Swift package tests pass from the root public SwiftPM manifest and from `libs/swift`.
- Docs build from `docs/content` through `docs/site/girk.json`.
- Root `npm run validate` runs Swift build, Swift tests, and docs build.
- `npm run validate:live` is the explicit release gate for opt-in live write tests against dedicated provider repositories.
- The monorepo layout uses `libs/swift` for the Apple implementation and leaves room for future sibling libraries such as `libs/kotlin` and `libs/typescript`.

Implemented in the current Swift package:

- Core provider-neutral models, stores, facade, URL resolution helpers, and validation.
- GitHub, GitLab, Forgejo/Gitea, and Bitbucket Cloud provider operations for account, repositories, branches, file read/list/commit/delete, branch create/delete, repository create, fork, and PR/MR create.
- `submitChange` orchestration for direct commit, branch + PR, fork + PR, and automatic selection.
- Provider-neutral OAuth facade start/complete methods, backed by GitHub device flow, GitLab PKCE, and Forgejo/Gitea browser OAuth provider implementations.
- Token refresh for expiring OAuth credentials, serialized per connection and persisted before provider/API or Git CLI credential use, with one reactive refresh-and-retry after an unexpected authentication failure.
- Apple Keychain credential storage in `GitPontKeychain`.
- HTTPS Git credential context support in `GitPontGitCLI`.
- Mocked unit coverage for provider requests/responses, reusable JSON fixtures, pagination, URL parsing, OAuth, refresh race behavior, Keychain payloads, Git CLI credentials, change submission, branch cleanup, and blind-overwrite safety.
- Partial-submission reporting for branch/fork submission sequences that fail after an intermediate step.

Remaining before calling v1 complete:

- A verified run of the opt-in live write tests against dedicated disposable GitHub, GitLab, Forgejo/Gitea, and Bitbucket Cloud repositories.

## Expected Repository Structure

```txt
package.json
libs/
  swift/
    Package.swift
    Sources/
      GitPontCore/
      GitPontGitHub/
      GitPontGitLab/
      GitPontForge/
      GitPontKeychain/
      GitPontGitCLI/
    Tests/
      GitPontCoreTests/
      GitPontGitHubTests/
        Fixtures/
      GitPontGitLabTests/
        Fixtures/
      GitPontForgeTests/
        Fixtures/
      GitPontGitCLITests/
docs/
  content/
  site/
kits/
  # reserved for app/demo kits if needed later
scripts/
```

## First Consumer Use Cases

### Lezin

Open a remote Markdown file URL, edit it, and save by committing through the provider API — directly when the user can push, via branch + PR, or via fork + PR when the user has no write access. Lezin does not need local Git.

### GitFolder

Use provider connections and credentials for HTTPS remotes while GitFolder continues to run its own sync loop through system `git`. Also: repository listing, branch listing, and remote repository creation during folder setup.

## Implementation Warnings

- Do not assume GitLab namespaces are one segment.
- Do not assume branch names are slash-free — URL parsing is two-phase (see Architecture).
- Do not assume custom domains are GitLab/Forgejo unless configured.
- Do not embed tokens in remote URLs.
- Do not overwrite remote files without conflict protection; blind overwrite requires an explicit opt-in flag.
- Do not read only the first page of any list endpoint.
- Do not run two concurrent token refreshes for one connection.
- Do not leave OAuth start/complete or refresh as app-specific behavior.
- Do not make `GitPontCore` depend on `GitPontGitCLI`.
- Do not make Markdown-specific APIs.
- Do not make UI components part of core.
- Do not put Keychain code in core.
- Do not hardcode consuming app names into the package.
