# Security

`git-pont` handles repository credentials and can write to user repositories. Security rules should be strict from the first commit.

## Secrets

Tokens must only live in a `CredentialStore`.

Do not store tokens in:

- app config JSON
- `GitConnection`
- `GitRepositoryReference`
- remote URLs
- logs
- thrown error messages
- test snapshots

## Logging

Logs may include:

- provider kind
- host
- repository namespace/name
- HTTP status code
- normalized error code

Logs must not include:

- access tokens
- refresh tokens
- authorization headers
- raw credential helper scripts containing token values
- full request bodies for write operations unless redacted

## URL Safety

Reject repository paths containing:

- `..`
- absolute local filesystem paths
- empty path segments after normalization where a file path is required
- NUL or control characters

## Commit Safety

Updating an existing file must include provider-specific version protection:

- GitHub: `sha`
- GitLab: `last_commit_id`
- Forgejo/Gitea: file SHA (required by the API)

If no expected version is available, updating or deleting an existing file requires the explicit caller option `allowBlindOverwrite: Bool` on `GitFileChange` / `GitFileDeleteRequest`. Default must be false; without it and without a version, throw `.conflict` rather than write.

Deleting a file must go through the explicit delete API. Committing empty content is never a delete.

## Refresh Safety

Token refresh must be serialized per connection (GitLab rotates refresh tokens; a duplicate concurrent refresh invalidates the surviving token). The refreshed credential must be persisted to `CredentialStore` before dependent requests proceed. See [Authentication → Token Refresh](authentication.md).

## Browser Auth

OAuth flows should:

- use PKCE when supported
- use secure random state
- validate state on callback
- avoid client secrets in native apps unless there is a backend
- store refresh tokens only in `CredentialStore`

## Keychain

`GitPontKeychain` should:

- use generic password items
- use a service name configurable by the consuming app
- use stable account IDs such as `git-pont:{connectionID}`
- prefer `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` for local app storage

## Git CLI

`GitPontGitCLI` must avoid token leakage:

- tokens must be passed through environment variables
- token values must not appear in command arguments (variable *names* in the helper script are fine)
- set `GIT_TERMINAL_PROMPT=0`
- do not mutate global git config
- do not write credential helpers to disk in v1

## Network

The package should not disable TLS verification.

Self-hosted instances with invalid certificates are not supported in v1. If this is added later, it must be an explicit app-level trust decision.

