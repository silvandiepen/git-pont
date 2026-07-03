# Architecture

`git-pont` should be a small integration library with a stable provider-neutral contract and provider-specific modules. The central idea is that apps talk to normalized concepts: connection, repository, branch, file reference, commit, and pull request. Provider modules translate those concepts to GitHub, GitLab, Forgejo, or Gitea APIs. Codeberg is a preset Forgejo instance, not a separate provider kind.

The v1 implementation is the Swift library, exposed as a Swift Package for Apple platforms. The architecture should still describe concepts that can be mirrored later by Android, web, or server libraries. Swift signatures in this document are canonical for v1 Swift; future libraries should translate them idiomatically while preserving behavior and field meanings.

## Design Principles

- Provider-neutral public API and models.
- Provider-specific behavior hidden behind protocol implementations.
- Async/await first.
- Dependency injection for networking, credentials, clock, and logging.
- No UI dependencies in core modules.
- No global singleton requirement.
- File content is raw `Data`, not `String`.
- Preserve remote version identifiers for conflict detection.
- Prefer explicit capabilities over assuming every provider supports every feature.
- Keep model semantics portable to Kotlin/TypeScript-style data models.

## Facade

`GitPont` is the app-facing entry point. This is the canonical public surface; integration docs and the README must match these signatures exactly.

```swift
public final class GitPont: Sendable {
    public init(
        providers: [GitProvider],
        connectionStore: ConnectionStore,
        credentialStore: CredentialStore,
        httpClient: HTTPClient
    )

    // URL handling
    public func parse(url: URL) throws -> GitURLParseResult
    public func resolve(_ result: GitURLParseResult) async throws -> GitURLReference

    // Files
    public func openFile(from url: URL) async throws -> GitRemoteFile
    public func readFile(_ reference: GitFileReference) async throws -> GitRemoteFile
    public func listDirectory(_ reference: GitFileReference) async throws -> GitList<GitDirectoryEntry>
    public func commitFile(_ change: GitFileChange) async throws -> GitCommitResult
    public func deleteFile(_ request: GitFileDeleteRequest) async throws -> GitCommitResult
    public func checkForRemoteChange(_ file: GitRemoteFile) async throws -> Bool

    // Repositories and branches
    public func repositories(connectionID: String) async throws -> GitList<GitRepository>
    public func repository(_ reference: GitRepositoryReference) async throws -> GitRepository
    public func branches(of repository: GitRepositoryReference) async throws -> GitList<GitBranch>
    public func createRepository(_ request: GitCreateRepositoryRequest, connectionID: String) async throws -> GitRepository
    public func createBranch(_ request: GitCreateBranchRequest) async throws -> GitBranch
    public func deleteBranch(_ request: GitDeleteBranchRequest) async throws
    public func forkRepository(_ reference: GitRepositoryReference, connectionID: String) async throws -> GitRepository

    // Pull requests and orchestration
    public func createPullRequest(_ request: GitPullRequestRequest) async throws -> GitPullRequest
    public func submitChange(_ submission: GitChangeSubmission) async throws -> GitChangeResult

    // OAuth
    public func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult
    public func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential

    // Connections
    public func connections() async throws -> [GitConnection]
    public func connection(for instance: GitProviderInstance, preferredConnectionID: String?) async throws -> GitConnection
    public func addConnection(instance: GitProviderInstance, credential: GitCredential, authMethod: GitAuthMethod) async throws -> GitConnection
    public func removeConnection(id: String) async throws
}
```

Convenience overload used by simple consumers:

```swift
public extension GitPont {
    func commitFile(
        _ reference: GitFileReference,
        content: Data,
        message: String,
        expectedVersion: GitRemoteVersion?
    ) async throws -> GitCommitResult
}
```

The facade resolves the provider and connection for each call, refreshes credentials when needed, and delegates to the provider implementation. Apps never talk to providers directly unless they choose to.

`GitPontCore` must not depend on the Git CLI module. `GitPontGitCLI` adds Git CLI support as a Swift extension:

```swift
public extension GitPont {
    func gitCredentialContext(
        forRemoteURL url: URL,
        preferredConnectionID: String? = nil
    ) async throws -> GitCLICredentialContext
}
```

`GitCLICredentialContext` is declared in `GitPontGitCLI`. Consumers that need this method import `GitPontGitCLI`; consumers like Lezin do not.

## Provider Protocol

```swift
public protocol GitProvider: Sendable {
    var kind: GitProviderKind { get }
    var displayName: String { get }
    var capabilities: GitProviderCapabilities { get }
    var changeRequestTerm: GitChangeRequestTerm { get }

    func canHandle(url: URL) -> Bool
    func parse(url: URL) throws -> GitURLParseResult
    func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount
    func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository>
    func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository
    func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch>
    func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile
    func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry>
    func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult
    func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult
    func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch
    func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws
    func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository
    func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository
    func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest
}
```

Provider request context carries the resolved connection metadata and credential for an operation:

```swift
public struct GitProviderRequestContext: Sendable {
    public var connection: GitConnection?
    public var credential: GitCredential?
}
```

Both fields are optional because public repositories may be readable without authentication. The facade must still prefer an authenticated context when one connection exists for the instance (unauthenticated GitHub requests are limited to 60/hour per IP). Write operations require both `connection` and `credential`; providers should throw `.authenticationRequired` if either is missing.

`GitConnection` remains metadata-only. Secrets are loaded from `CredentialStore` by the facade and passed to providers only in memory through `GitProviderRequestContext`.

## Provider Construction

Provider modules expose concrete provider types with explicit instance lists. Known public hosts are registered by default; custom/self-hosted instances are registered by the consuming app.

```swift
public struct GitHubProvider: GitProvider {
    public init(httpClient: HTTPClient, oauth: OAuthAppConfig?)
}

public struct GitLabProvider: GitProvider {
    public init(httpClient: HTTPClient, instances: [GitProviderInstance], oauth: OAuthAppConfig?)
}

public struct ForgeProvider: GitProvider {
    public init(httpClient: HTTPClient, instances: [GitProviderInstance], oauth: OAuthAppConfig?)
}
```

Default app setup:

```swift
let providers: [GitProvider] = [
    GitHubProvider(httpClient: httpClient, oauth: githubOAuth),
    GitLabProvider(httpClient: httpClient, instances: [.gitLabCloud], oauth: gitLabOAuth),
    ForgeProvider(httpClient: httpClient, instances: [.codeberg], oauth: nil)
]
```

Self-hosted setup adds explicit instances:

```swift
let companyGitLab = GitProviderInstance.gitLabSelfHosted(
    baseURL: URL(string: "https://company.com/gitlab")!,
    displayName: "Company GitLab"
)

let providers: [GitProvider] = [
    GitLabProvider(httpClient: httpClient, instances: [.gitLabCloud, companyGitLab], oauth: gitLabOAuth)
]
```

`canHandle(url:)` must only return true for known public hosts or the provider's configured instances. It must never infer that an arbitrary host is GitLab, Forgejo, or Gitea.

## Authentication Protocols

Authentication is split out from repository operations so PAT setup, OAuth start/complete, and token refresh are not invented by each app. Apps should call `GitPont.startOAuth(_:)` and `GitPont.completeOAuth(_:)` for provider-neutral OAuth orchestration, then pass the returned credential to `addConnection(instance:credential:authMethod:)`.

```swift
public protocol GitAuthenticationProvider: Sendable {
    func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String]
    func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult
    func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential
    func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential
}
```

Provider modules that support OAuth conform to `GitAuthenticationProvider`. PAT-only operation can still use `addConnection(instance:credential:authMethod:)` directly after the app collects a token.

Core OAuth models:

```swift
public struct GitOAuthStartRequest: Sendable {
    public var instance: GitProviderInstance
    public var method: GitAuthMethod
    public var appConfig: OAuthAppConfig
}

public enum GitOAuthStartResult: Sendable {
    case browser(GitOAuthBrowserSession)
    case device(GitOAuthDeviceSession)
}

public struct GitOAuthBrowserSession: Sendable {
    public var authorizationURL: URL
    public var state: String
    public var codeVerifier: String?
    public var redirectURI: URL
}

public struct GitOAuthDeviceSession: Sendable {
    public var verificationURI: URL
    public var userCode: String
    public var deviceCode: String
    public var interval: TimeInterval
    public var expiresAt: Date
}

public struct GitOAuthCompletionRequest: Sendable {
    public var instance: GitProviderInstance
    public var method: GitAuthMethod
    public var appConfig: OAuthAppConfig
    public var callbackURL: URL?
    public var state: String?
    public var codeVerifier: String?
    public var deviceCode: String?
}
```

The Swift library may add helper wrappers for opening browser sessions, listening for callback URLs, or polling device codes, but the provider-neutral core owns the models above.

## Core Workflow

1. App passes a URL to `GitPont`.
2. `GitPont` asks registered providers which can handle it.
3. Provider parses the URL into a `GitURLParseResult`.
4. If the result is ambiguous (see below), `GitPont` resolves it against the branch list.
5. `GitPont` resolves a matching connection if authentication is needed.
6. Provider reads the file or repository metadata.
7. App edits content.
8. App asks `GitPont` to commit a file change or submit a change (branch/fork + PR).
9. Provider sends the correct API request and returns a normalized result.

## URL Parsing Is Two-Phase

Blob URLs cannot always be parsed purely syntactically. Branch names may contain slashes, so in

```txt
https://github.com/owner/repo/blob/feature/foo/doc.md
```

the ref may be `feature` (path `foo/doc.md`) or `feature/foo` (path `doc.md`). The same applies to GitLab and Forgejo/Gitea URLs.

Parsing therefore returns:

```swift
public enum GitURLParseResult: Sendable {
    case resolved(GitURLReference)
    case ambiguous(candidates: [GitURLReference])
}
```

- `parse(url:)` is synchronous and never touches the network.
- `resolve(_:)` disambiguates `.ambiguous` by listing branches through the API and selecting the longest branch name that matches a prefix of the ref+path remainder. If no candidate matches a real branch, throw `.unsupportedURL`.
- `openFile(from:)` performs both phases internally; most apps only need `openFile`.
- A single-segment ref is returned as `.resolved` (the common case); ambiguity only arises when the remainder after the ref marker has three or more segments.

Parsers must strip query strings and fragments (for example `#L10` line anchors) before matching, and must accept commit-SHA permalinks (a 7–64 character hex ref is treated as resolved, never ambiguous).

## Provider Registry

Provider resolution should be deterministic:

1. Exact known platform hosts:
   - `github.com` (including `raw.githubusercontent.com`)
   - `gitlab.com`
   - `codeberg.org`
2. Configured self-hosted instances.
3. Custom URL parser fallback only when the app explicitly provides an instance config.

Avoid guessing that an arbitrary domain is GitLab or Forgejo. Require a configured connection for custom domains.

## Connection Resolution

When an operation needs a connection for an instance:

1. If the caller passed `preferredConnectionID` and it matches the instance, use it.
2. If exactly one connection exists for the instance, use it.
3. If multiple connections exist, throw `.ambiguousConnection(instanceID:candidates:)` so the app can present a picker.
4. If none exists, throw `.missingConnection` (or proceed unauthenticated for reads where the capability allows it).

## Capabilities

Providers should expose capabilities so apps can adapt UI:

```swift
public struct GitProviderCapabilities: OptionSet, Sendable {
    public static let publicFileRead
    public static let authenticatedFileRead
    public static let fileCommit
    public static let fileDelete
    public static let batchCommit
    public static let directoryList
    public static let branchCreate
    public static let repositoryCreate
    public static let repositoryFork
    public static let pullRequestCreate
    public static let gitCLICredentials
}
```

There is a single `pullRequestCreate` capability for all providers. The PR-vs-MR wording difference is a UI label, not a capability:

```swift
public enum GitChangeRequestTerm: String, Sendable, Codable {
    case pullRequest
    case mergeRequest
}
```

`batchCommit` (multiple files in one commit) is a declared capability but has no v1 API surface; do not build it until a consumer needs it.

## Change Submission

Apps like Lezin need "save this edit as a direct commit, a branch + PR, or a fork + branch + PR" as one operation. Stitching those calls in every app duplicates partial-failure handling, so core owns it:

```swift
public struct GitChangeSubmission: Sendable {
    public enum Strategy: Sendable {
        case directCommit
        case branchAndPullRequest(branchName: String, title: String, body: String?, draft: Bool)
        case forkAndPullRequest(branchName: String, title: String, body: String?, draft: Bool)
        case automatic(branchName: String, title: String, body: String?, draft: Bool)
    }

    public var change: GitFileChange
    public var strategy: Strategy
}

public struct GitChangeResult: Sendable {
    public var commit: GitCommitResult
    public var pullRequest: GitPullRequest?
    public var usedRepository: GitRepositoryReference   // the fork when forking was used
    public var usedBranch: String
}
```

`.automatic` picks the cheapest strategy the user's permissions allow: direct commit if the user can push to the target branch, else branch + PR if the user can push to the repository, else fork + PR. Permission data comes from `GitRepository.permissions` (see [Provider Model](provider-model.md)).

Fork flow details:

- Reuse an existing fork when the provider reports one; otherwise create it.
- After creating a fork, poll repository availability (forking is async on GitHub) with a bounded wait (10 attempts, 1s apart) before committing.
- The PR is opened on the upstream repository with the fork branch as source (`owner:branch` head on GitHub, `source_project_id` on GitLab, `owner:branch` on Forgejo/Gitea).

Partial-failure rules:

- If branch creation succeeds but the commit fails, surface the error via `.partialSubmission` naming the created branch so the app can inspect or clean up through `deleteBranch`.
- If the commit succeeds but PR creation fails, return `.partialSubmission` carrying the successful `GitChangeResult` (without PR) so the app can retry PR creation without recommitting.

## Pagination

GitHub, GitLab, Forgejo, and Gitea paginate all list endpoints. Providers must:

- request the maximum page size (`per_page=100`),
- follow pagination (GitHub/Forgejo/Gitea `Link` headers, GitLab `x-next-page`) until exhausted,
- stop at a safety cap of 30 pages (3,000 items) and mark the result truncated.

List methods return complete, internally-paginated results. Apps never see page tokens in v1:

```swift
public struct GitList<Element: Sendable>: Sendable {
    public var items: [Element]
    public var truncated: Bool
}
```

## Retry Policy

Core provides a default `RetryPolicy` applied by the facade:

- Retry idempotent reads (GET) up to 3 times on HTTP 429 and 5xx, honoring `Retry-After` when present, otherwise exponential backoff (1s, 2s, 4s) with jitter.
- Never automatically retry writes (commit, delete, branch, PR, fork). Map 429 on writes to `.rateLimited(retryAfter:)` and let the app decide.
- The policy and its sleep function are injectable so tests run with zero delay.

## Error Model

Errors must be normalized but preserve provider details:

```swift
public enum GitPontError: Error, Sendable {
    case unsupportedURL(String)
    case ambiguousURL(candidates: [GitURLReference])
    case missingConnection(GitProviderKind)
    case ambiguousConnection(instanceID: String, candidates: [GitConnection])
    case authenticationRequired
    case authenticationFailed(String)
    case permissionDenied(String)
    case notFound(String)
    case conflict(GitConflict)
    case fileTooLarge(size: Int?, limit: Int)
    case rateLimited(retryAfter: TimeInterval?)
    case providerUnavailable(String)
    case unsupportedCapability(String)
    case invalidProviderResponse(String)
    case partialSubmission(completed: GitChangeResult, failure: String)
}
```

Error messages must never contain token values (see [Security](security.md)).

## Version Identity

Each loaded file must carry a provider-specific version identity. This is required to prevent overwriting remote changes.

```swift
public enum GitRemoteVersion: Hashable, Sendable, Codable {
    case blobSHA(String)      // GitHub, Forgejo, Gitea file/blob SHA
    case commitID(String)     // GitLab last_commit_id, or commit-level identity
    case opaque(provider: GitProviderKind, value: String)
}
```

When committing a file, include the known version where the provider supports it. If the provider reports a conflict, return `.conflict` with:

```swift
public struct GitConflict: Hashable, Sendable {
    public var reference: GitFileReference
    public var expectedVersion: GitRemoteVersion?
    public var remoteVersion: GitRemoteVersion?   // when the provider reports it
    public var providerMessage: String?
}
```

`GitConflict` intentionally does not carry remote content; apps that want a diff should call `readFile` after receiving the conflict.

## HTTP Abstraction

Core defines the transport types so all providers are testable without the network:

```swift
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?
}

public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data
}

public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}
```

`GitPontCore` includes `URLSessionHTTPClient` for app and opt-in live integration use. Unit tests should continue to inject mock clients so default validation never depends on network access.

Header lookup on `HTTPResponse` must be case-insensitive.
