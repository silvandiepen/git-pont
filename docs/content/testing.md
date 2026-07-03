# Testing Strategy

`git-pont` must be heavily tested because provider integrations break easily and app data loss would be unacceptable.

## Test Layers

1. Pure model tests
2. URL parser tests (including ambiguity)
3. Request construction tests
4. Response decoding tests
5. Pagination tests
6. Error mapping tests
7. Credential and connection store tests
8. Token refresh tests
9. Git CLI credential tests
10. Provider contract tests with mocked HTTP
11. Change submission (orchestration) tests
12. Optional live integration tests gated by environment variables

## Mocked HTTP

Core defines the injectable `HTTPClient` (see [Architecture → HTTP Abstraction](architecture.md)). Tests use a `MockHTTPClient` that matches requests by method + URL pattern and replays fixture responses, recording every request for assertion.

Tests should not hit the network by default.

Use fixture-driven tests. SwiftPM keeps resources per test target, so each provider target owns its provider fixture files:

```txt
libs/swift/Tests/GitPontGitHubTests/Fixtures/GitHub/read-file.json
libs/swift/Tests/GitPontGitHubTests/Fixtures/GitHub/list-directory.json
libs/swift/Tests/GitPontGitLabTests/Fixtures/GitLab/read-file.json
libs/swift/Tests/GitPontGitLabTests/Fixtures/GitLab/list-directory.json
libs/swift/Tests/GitPontForgeTests/Fixtures/Forgejo/read-file.json
libs/swift/Tests/GitPontForgeTests/Fixtures/Forgejo/list-directory.json
```

Add new provider response cases as JSON fixtures where the payload is reusable across future Android, web, or backend kits. Keep request-only assertions inline when there is no response payload worth sharing.

## URL Parser Matrix

Test at least:

- GitHub blob URL
- GitHub blob URL with commit-SHA permalink
- GitHub blob URL with `#L10` fragment and query string (stripped)
- GitHub raw URL (including `refs/heads/` form)
- GitHub tree (directory) URL
- GitHub repo URL, with and without `.git`
- GitHub blob URL with slashed branch → `.ambiguous` with correct candidate order
- GitLab blob URL
- GitLab raw URL (`/-/raw/`)
- GitLab subgroup blob URL
- GitLab self-hosted blob URL (configured instance)
- GitLab repo URL
- Codeberg `src/branch/` URL
- Codeberg `src/commit/{sha}` URL
- Forgejo custom source URL
- Gitea custom source URL
- invalid URL
- unsupported host
- custom host without configured instance

Resolution tests: `.ambiguous` result + mocked branch list → correct `(ref, path)` chosen; no matching branch → `.unsupportedURL`.

## Pagination Tests

- Multi-page branch and repository lists are concatenated (GitHub `Link` header, GitLab `x-next-page`).
- Safety cap sets `truncated = true` and stops requesting.
- `per_page=100` is sent on list requests.

## Conflict Tests

Test that commits include provider version identity:

- GitHub sends `sha`
- GitLab sends `last_commit_id`
- Forgejo/Gitea sends `sha`

Test provider conflict responses map to `GitPontError.conflict(...)` with a populated `GitConflict`.

Test that `GitCommitResult.newVersion` is populated after a successful commit for every provider (including GitLab's follow-up read).

## Change Submission Tests

With mocked HTTP:

- `.directCommit` performs one commit call.
- `.branchAndPullRequest` creates branch, commits, opens PR; PR request uses the right head format.
- `.forkAndPullRequest` creates or reuses the connected account's fork, confirms newly created forks, commits to the fork, and opens PR on upstream with fork head (`owner:branch` / `target_project_id`).
- `.automatic` picks direct commit when `permissions.canPush` and the branch is not protected; branch+PR when push but protected/PR requested; fork+PR when `canPush == false`.
- Commit success + PR failure → `.partialSubmission` carrying the commit result.
- Branch success + commit failure → `.partialSubmission` naming the branch.

## Credential and Connection Tests

Use in-memory stores in core tests:

```swift
final actor InMemoryCredentialStore: CredentialStore
final actor InMemoryConnectionStore: ConnectionStore
```

Keychain tests live in `GitPontKeychainTests`. The default suite verifies the credential payload round trip. A live Keychain save/load/update/delete test is opt-in with `GITPONT_RUN_KEYCHAIN_TESTS=1`.

Test:

- save/load/delete for both stores
- token not serialized in connection metadata (encode `GitConnection`, assert no token substring)
- missing credential returns `nil`
- `removeConnection` deletes both metadata and credential

## Token Refresh Tests

- Expiring credential triggers refresh before the request; refreshed token is used.
- Concurrent requests against one expiring connection produce exactly one refresh call (assert via mock request count).
- Refreshed credential is saved to the store before dependent requests run.
- Git CLI credential context uses a refreshed token for expiring OAuth credentials.
- Refresh failure does not delete the connection.
- Unexpected provider authentication failure triggers one refresh-and-retry when a refresh token exists.

## Git CLI Credential Tests

Test that:

- tokens are placed in environment, not command arguments (assert token value absent from every `argumentsPrefix` element)
- `GIT_TERMINAL_PROMPT=0` is set
- GitHub, GitLab, and Forgejo contexts use provider-appropriate usernames
- unknown provider returns `.unsupportedCapability`
- missing connection returns `.missingConnection`
- multiple connections without `preferredConnectionID` returns `.ambiguousConnection`; with it, the preferred one is used

## Live Tests

Live tests are disabled by default and require explicit environment variables. The checked-in live suite performs account smoke tests through `URLSessionHTTPClient` when a token is present:

```txt
GITPONT_LIVE_GITHUB_TOKEN
GITPONT_LIVE_GITLAB_TOKEN
GITPONT_LIVE_FORGEJO_TOKEN
GITPONT_LIVE_FORGEJO_BASE_URL   # optional, defaults to Codeberg
```

The checked-in live suite also includes opt-in disposable write cycles. These create a temporary branch, create/read/delete a file under `.git-pont-live/`, and delete the temporary branch. Configure them only with dedicated test repositories:

```txt
GITPONT_LIVE_GITHUB_WRITE_REPO          # owner/repo
GITPONT_LIVE_GITHUB_WRITE_BASE_REF      # optional, defaults to main
GITPONT_LIVE_GITLAB_WRITE_REPO          # namespace/project
GITPONT_LIVE_GITLAB_WRITE_BASE_REF      # optional, defaults to main
GITPONT_LIVE_FORGEJO_WRITE_REPO         # owner/repo
GITPONT_LIVE_FORGEJO_WRITE_BASE_REF     # optional, defaults to main
```

Never run live write tests in normal CI unless a dedicated test repo is configured.

Use `npm run validate:live` as the release gate for all configured live provider write cycles. It fails fast when any required token or disposable repository variable is missing.

## Safety Tests

Add tests that prevent common data-loss behavior:

- updating an existing file without expected version and without `allowBlindOverwrite` throws `.conflict` (no request sent)
- deleting without expected version and without `allowBlindOverwrite` is rejected
- path traversal segments (`..`) are rejected
- absolute file paths are rejected as repository paths
- NUL/control characters in paths are rejected
- empty commit message is rejected
- delete requires the explicit delete API; empty-content commit is not a delete
- files above the provider size limit throw `.fileTooLarge`, not a decode error
