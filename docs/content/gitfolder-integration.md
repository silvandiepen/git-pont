# GitFolder Integration

GitFolder is an end-user menu bar app that syncs local folders to remote repositories. It should use `git-pont` for platform connections and credential resolution, not for the sync engine itself.

## Current GitFolder Shape

GitFolder currently:

- stores selected folders with security-scoped bookmarks
- runs system `git`
- initializes repos
- configures remotes
- creates snapshot commits
- pulls with rebase
- pushes to remote
- has GitHub device auth
- stores a GitHub token in Keychain
- injects GitHub token through a Git credential helper

## Target Shape

Replace GitHub-specific auth and language with provider-neutral connections.

Current concepts:

```swift
githubToken
hasGitHubToken
GitHubOAuthService
AuthMode.githubToken
GitSyncError.missingGitHubToken
testGitHubAccess
```

Target concepts:

```swift
GitConnection
hasProviderConnection
GitPont
AuthMode.providerToken
GitSyncError.missingProviderConnection
testRepositoryAccess
```

## Folder Model

Evolve `SyncedFolder`:

```swift
struct SyncedFolder {
    var repoUrl: String
    var provider: String        // GitProviderKind rawValue
    var connectionID: String?
    var branch: String
}
```

Avoid storing tokens in folder config. Always store `connectionID` on new folders so multi-account users never hit `.ambiguousConnection` during background sync.

## Folder Setup Flow

1. User picks a local folder.
2. User picks a connection (or creates one).
3. User picks an existing repository via `gitPont.repositories(connectionID:)` — **or creates a new one** via `gitPont.createRepository(_:connectionID:)` (name defaulted from the folder name, private by default). This removes the "go create a repo in the browser first" step.
4. User picks a branch via `gitPont.branches(of:)`, defaulting to the repository default branch.
5. GitFolder stores `repoUrl` from `GitRepository.reference.cloneHTTPSURL`, plus `connectionID` and `branch`.

Repository access check (`testRepositoryAccess`) uses `gitPont.repository(_:)` and verifies `permissions.canPush`.

## Sync Engine Integration

Before running remote Git commands, resolve a fresh credential context (contexts are single-use; OAuth tokens may have been refreshed since the last run):

```swift
let context = try await gitPont.gitCredentialContext(
    forRemoteURL: URL(string: folder.repoUrl)!,
    preferredConnectionID: folder.connectionID
)
```

Then use:

```swift
git(context.argumentsPrefix + ["pull", "--rebase", "origin", folder.branch], environment: context.environment)
git(context.argumentsPrefix + ["push", "-u", "origin", folder.branch], environment: context.environment)
```

Error handling in the sync loop:

- `.missingConnection` / `.authenticationFailed` → mark the folder as needing reconnect; do not retry until the user acts.
- `.ambiguousConnection` → prompt once, store the chosen `connectionID` on the folder.
- `.rateLimited(retryAfter:)` → skip this cycle and delay the next sync by at least `retryAfter`.

## Settings UI

Replace "GitHub" settings with "Connections":

```txt
Connections
├─ GitHub
├─ GitLab.com
├─ Self-hosted GitLab
├─ Codeberg
├─ Forgejo
└─ Gitea
```

Folder setup:

```txt
Local folder
Connection
Repository (pick existing or create new)
Branch
Sync interval
```

## Migration

Existing GitFolder installs may have:

- provider: `github`
- authMode: `github_token`
- GitHub token in Keychain account `github-token`

Migration should:

1. Detect existing GitHub token.
2. Validate it by loading the account (`gitPont.addConnection` does this) and create a GitPont GitHub connection.
3. Move or duplicate the token into GitPont credential storage.
4. Update folders to reference the new `connectionID`.
5. Keep the old token until migration succeeds; delete it only after a successful sync through the new path.

If validation fails (revoked/expired token), keep the old state, mark affected folders as needing reconnect, and show the connection flow.

## SSH

Do not route SSH through GitPont v1.

GitFolder may keep its existing advanced SSH mode separately, but the default flow should be provider account connections over HTTPS.
