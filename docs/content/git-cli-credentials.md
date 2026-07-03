# Git CLI Credentials

`GitPontGitCLI` exists for apps like GitFolder that shell out to system `git`.

It should not perform sync operations. It only resolves provider credentials into a safe, non-interactive Git credential context.

## Credential Context

`GitPontGitCLI` owns this type and adds the `gitCredentialContext` method as an extension on `GitPont`. `GitPontCore` must not import or depend on `GitPontGitCLI`.

```swift
public struct GitCLICredentialContext: Hashable, Sendable {
    public var argumentsPrefix: [String]        // e.g. ["-c", "credential.helper=..."]
    public var environment: [String: String]
}
```

This is the only shape. There is no separate `helperConfig` accessor; `argumentsPrefix` is prepended to the git argument list as-is.

Usage:

```swift
let context = try await gitPont.gitCredentialContext(
    forRemoteURL: remoteURL,
    preferredConnectionID: folder.connectionID
)
let result = try gitRunner.run(
    context.argumentsPrefix + ["ls-remote", "--heads", remoteURL.absoluteString],
    environment: context.environment
)
```

## HTTPS Token Auth

For HTTPS remotes, prefer an inline credential helper with an environment variable, not embedding tokens in remote URLs.

Example shape:

```txt
git -c credential.helper='!f() { printf "username=%s\npassword=%s\n" "$GITPONT_USERNAME" "$GITPONT_TOKEN"; }; f' ...
```

Environment:

```txt
GITPONT_USERNAME=...
GITPONT_TOKEN=...
GIT_TERMINAL_PROMPT=0
```

The token value appears only in `environment`, never in `argumentsPrefix`. The helper script text in `argumentsPrefix` references the variables by name.

If the credential for the connection is an expiring OAuth token, the facade refreshes it before building the context (see [Authentication → Token Refresh](authentication.md)). Contexts are single-use: request a fresh context per sync run rather than caching one.

Provider username defaults:

- GitHub OAuth/PAT: `x-access-token`
- GitLab OAuth: `oauth2`; GitLab PAT: the account login (or any non-empty username; GitLab accepts the PAT as password)
- Forgejo/Gitea/Codeberg: account login when known, otherwise token-compatible placeholder

Provider implementations should own these details.

## Remote URL Matching

Given a remote URL:

```txt
https://github.com/owner/repo.git
https://gitlab.com/group/project.git
https://gitlab.company.com/group/project.git
https://codeberg.org/owner/repo.git
```

GitPont should:

1. Normalize the URL (strip `.git`, trailing slashes, credentials in the URL if present).
2. Resolve the provider instance (known hosts first, then configured instances).
3. Find a connection for the instance, honoring `preferredConnectionID`; multiple matches without a preference throw `.ambiguousConnection`.
4. Load credentials, refreshing if needed.
5. Return CLI context.

If no matching connection exists, throw `.missingConnection`.

## No SSH in v1

Do not implement SSH credential handling in GitPont v1.

GitFolder can keep its existing advanced SSH path if desired, but provider-based account connections should be the default and documented route.
