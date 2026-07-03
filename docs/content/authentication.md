# Authentication

Authentication must be provider-neutral from the app perspective and provider-specific internally.

## Auth Methods

```swift
public enum GitAuthMethod: String, Hashable, Sendable, Codable {
    case oauthDevice
    case oauthPKCE
    case personalAccessToken
}
```

Do not include SSH in v1. Sandboxed macOS apps make SSH key access, `ssh-agent`, known hosts, and prompts unreliable. GitFolder may keep its own advanced SSH mode outside `git-pont`, but the main GitPont path should be platform account connections.

## Credential Store

Core should define a protocol only:

```swift
public protocol CredentialStore: Sendable {
    func save(_ credential: GitCredential, for connectionID: String) async throws
    func loadCredential(for connectionID: String) async throws -> GitCredential?
    func deleteCredential(for connectionID: String) async throws
}
```

Apple implementation should live in `GitPontKeychain`.

Secrets must not be encoded into app config JSON.

## Connection Store

Core also defines where connection metadata lives, so Lezin and GitFolder do not each invent their own persistence:

```swift
public protocol ConnectionStore: Sendable {
    func save(_ connection: GitConnection) async throws
    func connections() async throws -> [GitConnection]
    func connection(id: String) async throws -> GitConnection?
    func delete(id: String) async throws
}
```

Core ships two implementations:

- `InMemoryConnectionStore` (actor) for tests.
- `FileConnectionStore` writing JSON to an app-provided directory URL. Connections contain no secrets, so plain JSON is acceptable.

Removing a connection through the facade (`removeConnection(id:)`) deletes both the connection metadata and its credential.

## Credential Model

```swift
public struct GitCredential: Hashable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var tokenType: String?
    public var expiresAt: Date?
    public var scopes: [String]
}
```

## GitHub

Preferred auth:

- OAuth device flow for native apps.
- PAT fallback for advanced/manual setup.

Required scopes depend on feature:

- Repository read/write and PR creation need repo-level access (`repo` scope for classic tokens).
- Fork creation also works with `repo` scope.
- Fine-grained token support should be documented in UI, but core should accept opaque tokens.
- Organizations enforcing SAML SSO may reject otherwise-valid classic tokens; surface the provider message via `.permissionDenied` so users understand they must authorize the token for the org.

## GitLab.com and Self-Hosted GitLab

Preferred auth:

- OAuth with PKCE when an OAuth application is configured.
- PAT fallback.

Important scope detail:

- Repository Files API write operations require `api` scope.
- `read_repository` can read.
- `write_repository` is for Git-over-HTTP and should not be treated as enough for REST API file writes.

Token lifetime detail (load-bearing, not optional):

- GitLab OAuth access tokens expire after about 2 hours and always come with a refresh token. Any GitLab OAuth integration without working refresh will break within a session.
- GitLab PATs do not auto-expire (unless configured) and need no refresh.

Self-hosted GitLab connection requires:

- base URL
- auth method
- optional custom display name

## Forgejo, Gitea, Codeberg

Supported auth:

- Token auth.
- OAuth where available and configured on the instance.

Forgejo and Gitea instance variance is expected. Apps should allow PAT/token setup as the reliable path.

Forgejo accepts:

- `Authorization: Bearer ...`
- `Authorization: token ...`

Provider implementation should use `Authorization: token ...` for PATs and `Authorization: Bearer ...` for OAuth tokens, covered by tests.

## Connection Flow

PAT/token connection flow:

1. User chooses provider.
2. App creates or selects `GitProviderInstance`.
3. User pastes token.
4. Provider validates token by loading current account.
5. Facade saves connection metadata through `ConnectionStore`.
6. Facade saves the secret through `CredentialStore`.

Steps 5 and 6 are wrapped by `GitPont.addConnection(instance:credential:authMethod:)`.

OAuth connection flow:

1. User chooses provider.
2. App creates or selects `GitProviderInstance`.
3. App calls `GitPont.startOAuth(_:)`.
4. For `.browser`, the app opens `authorizationURL` and later passes the callback URL to `completeOAuth(_:)`.
5. For `.device`, the app shows `verificationURI` and `userCode`, then polls by calling `GitPont.completeOAuth(_:)` with the `deviceCode` at the returned interval until completion or expiry.
6. Provider returns `GitCredential`.
7. App calls `GitPont.addConnection(instance:credential:authMethod:)`.

Core defines the provider-neutral OAuth request/session models in [Architecture → Authentication Protocols](architecture.md). Provider modules still implement `GitAuthenticationProvider`; apps normally use the `GitPont` facade.

## OAuth App Ownership

Core supports injected OAuth configuration only:

```swift
public struct OAuthAppConfig: Sendable {
    public var clientID: String
    public var clientSecret: String?   // avoid in native apps; only for backend-mediated flows
    public var redirectURI: URL?
    public var scopes: [String]
}
```

GitPont ships no default client IDs. Each consuming app registers its own OAuth apps and passes the config. PAT/token auth works without any OAuth app setup and is the guaranteed path for every provider.

## Token Refresh

If a credential has a `refreshToken` and `expiresAt`, the facade refreshes automatically before requests when the token is within 60 seconds of expiry. If a provider still reports authentication failure, the facade performs one forced refresh and retries the operation once. PAT credentials without `refreshToken` are used as-is.

Refresh is delegated to the matching provider through `GitAuthenticationProvider.refreshCredential(_:instance:)`. Providers that do not support refresh return `.unsupportedCapability` only when asked to refresh a credential that claims to be refreshable.

Refresh must be race-free:

- Refresh is serialized per connection through an actor. Concurrent requests against an expiring connection await one shared refresh; there must never be two in-flight refreshes for the same connection (GitLab rotates refresh tokens, so a duplicate refresh invalidates the winner).
- The refreshed credential is saved to `CredentialStore` before the refresh actor releases waiting requests.

If refresh fails:

- return `.authenticationFailed`
- do not delete the existing connection automatically
- let the app offer reconnect

Provider-specific refresh endpoints:

- GitLab OAuth: call the instance OAuth token endpoint with `grant_type=refresh_token`; this is required because GitLab rotates refresh tokens.
- GitHub device flow: refresh only when the returned credential includes a refresh token and expiry; otherwise treat the token as non-refreshing.
- Forgejo/Gitea OAuth: refresh only for instances configured with OAuth metadata; PAT/token auth remains the reliable fallback.

## Multiple Accounts

Multiple connections may exist for the same instance (for example a personal and a work GitHub account). Resolution order is defined in [Architecture → Connection Resolution](architecture.md): explicit `preferredConnectionID` wins, a single match is used automatically, multiple matches throw `.ambiguousConnection` so the app can ask the user. Apps that persist a per-document or per-folder `connectionID` avoid the picker entirely.
