# Provider Model

The provider model separates provider kind, instance, account, connection, repository, and file reference. All types referenced by the [Architecture](architecture.md) facade and provider protocol are defined here.

These Swift definitions are canonical for the v1 Swift library. Future Android, web, or backend libraries should mirror the same fields and behavior with idiomatic platform types. Codable/raw-value choices should remain compatible with JSON-like persistence and cross-platform fixtures.

## Provider Kind

```swift
public enum GitProviderKind: String, Hashable, Sendable, Codable {
    case github
    case gitLabCloud
    case gitLabSelfHosted
    case forgejo
    case gitea
}
```

There is no `codeberg` kind. Codeberg is a preset `forgejo` instance (see below). Raw string values are the Codable representation; never rely on enum case ordering.

## Instance

```swift
public struct GitProviderInstance: Hashable, Sendable, Codable {
    public var id: String
    public var kind: GitProviderKind
    public var baseURL: URL
    public var apiBaseURL: URL
    public var displayName: String
}
```

Core ships preset factories so hosts are defined in exactly one place:

```swift
public extension GitProviderInstance {
    static let github: GitProviderInstance      // https://github.com / https://api.github.com
    static let gitLabCloud: GitProviderInstance // https://gitlab.com / https://gitlab.com/api/v4
    static let codeberg: GitProviderInstance    // kind .forgejo, https://codeberg.org / https://codeberg.org/api/v1

    static func gitLabSelfHosted(baseURL: URL, displayName: String?) -> GitProviderInstance
    static func forgejo(baseURL: URL, displayName: String?) -> GitProviderInstance
    static func gitea(baseURL: URL, displayName: String?) -> GitProviderInstance
}
```

Examples:

```txt
GitHub:
baseURL    https://github.com
apiBaseURL https://api.github.com

GitLab.com:
baseURL    https://gitlab.com
apiBaseURL https://gitlab.com/api/v4

Self-hosted GitLab:
baseURL    https://gitlab.company.com
apiBaseURL https://gitlab.company.com/api/v4

Codeberg (preset Forgejo):
baseURL    https://codeberg.org
apiBaseURL https://codeberg.org/api/v1

Forgejo/Gitea:
baseURL    https://git.example.com
apiBaseURL https://git.example.com/api/v1
```

Self-hosted factories must accept a `baseURL` that includes a path prefix (for example `https://company.com/gitlab`) and derive `apiBaseURL` from it.

## Account

```swift
public struct GitAccount: Hashable, Sendable, Codable {
    public var id: String          // provider account ID, stringified
    public var login: String
    public var displayName: String?
    public var avatarURL: URL?
    public var email: String?      // only when the provider returns it
}
```

## Connection

```swift
public struct GitConnection: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var instance: GitProviderInstance
    public var accountID: String
    public var accountLogin: String
    public var displayName: String?
    public var authMethod: GitAuthMethod
    public var createdAt: Date
    public var updatedAt: Date
}
```

The connection stores metadata only. Secrets live in `CredentialStore`. Connection persistence is owned by `ConnectionStore` (see [Authentication](authentication.md)).

## Repository Reference

```swift
public struct GitRepositoryReference: Hashable, Sendable, Codable {
    public var instance: GitProviderInstance
    public var namespace: String
    public var name: String
    public var defaultBranch: String?
    public var webURL: URL?
    public var cloneHTTPSURL: URL?
}
```

`namespace` may contain slashes for GitLab and Forgejo organization nesting.

## Repository

`GitRepository` is the full metadata form returned by list/get/create/fork operations. It embeds a reference plus permission data needed by `submitChange`:

```swift
public struct GitRepository: Hashable, Sendable, Codable {
    public var reference: GitRepositoryReference
    public var description: String?
    public var isPrivate: Bool
    public var isFork: Bool
    public var parent: GitRepositoryReference?       // upstream when this is a fork
    public var permissions: GitRepositoryPermissions
    public var updatedAt: Date?
}

public struct GitRepositoryPermissions: Hashable, Sendable, Codable {
    public var canRead: Bool
    public var canPush: Bool
    public var canAdmin: Bool
}
```

Permission mapping:

- GitHub: `permissions.pull/push/admin` on the repository object.
- GitLab: `permissions.project_access.access_level` (push requires Developer, level ≥ 30).
- Forgejo/Gitea: `permissions.pull/push/admin`.

When the provider omits permissions (unauthenticated read), default to `canRead: true, canPush: false, canAdmin: false`.

## Branch

```swift
public struct GitBranch: Hashable, Sendable, Codable {
    public var name: String
    public var commitSHA: String
    public var isDefault: Bool
    public var isProtected: Bool
}
```

## File Reference

```swift
public struct GitFileReference: Hashable, Sendable, Codable {
    public var repository: GitRepositoryReference
    public var path: String
    public var ref: String
    public var webURL: URL?
}
```

`ref` may be a branch, tag, or commit. For writes, it should usually be a branch.

## URL Reference

The result of parsing a provider URL:

```swift
public struct GitURLReference: Hashable, Sendable {
    public var instance: GitProviderInstance
    public var namespace: String
    public var name: String
    public var ref: String?      // nil for bare repository URLs
    public var path: String?     // nil for repository or ref-only URLs
}
```

## Loaded File

```swift
public struct GitRemoteFile: Hashable, Sendable {
    public var reference: GitFileReference
    public var content: Data
    public var encoding: GitFileEncoding
    public var version: GitRemoteVersion?
    public var size: Int?
    public var lastCommitID: String?
    public var etag: String?
}

public enum GitFileEncoding: String, Hashable, Sendable, Codable {
    case utf8      // provider returned text; content is the UTF-8 bytes
    case binary    // provider returned raw or Base64-decoded binary data
}
```

Providers decode Base64 transport encoding before returning; `content` is always the real file bytes. `encoding` records whether the provider identified the content as text. Apps must not assume `utf8` and should check before rendering as a string.

## Directory Entry

```swift
public struct GitDirectoryEntry: Hashable, Sendable, Codable {
    public enum EntryType: String, Sendable, Codable {
        case file
        case directory
        case symlink
        case submodule
    }

    public var name: String
    public var path: String
    public var type: EntryType
    public var size: Int?
}
```

## File Change

```swift
public struct GitFileChange: Sendable {
    public var reference: GitFileReference
    public var content: Data
    public var message: String
    public var targetBranch: String
    public var baseBranch: String?          // create targetBranch from this branch when it does not exist (GitLab start_branch semantics)
    public var expectedVersion: GitRemoteVersion?
    public var allowBlindOverwrite: Bool    // default false; see Security
    public var authorName: String?
    public var authorEmail: String?
}
```

A `GitFileChange` with no `expectedVersion` creates the file if it does not exist. Updating an existing file without `expectedVersion` requires `allowBlindOverwrite = true`, otherwise the provider must throw `.conflict`.

## File Delete

```swift
public struct GitFileDeleteRequest: Sendable {
    public var reference: GitFileReference
    public var message: String
    public var targetBranch: String
    public var expectedVersion: GitRemoteVersion?   // required unless allowBlindOverwrite
    public var allowBlindOverwrite: Bool            // default false
    public var authorName: String?
    public var authorEmail: String?
}
```

Deletion is an explicit API. Committing empty content must never be treated as a delete.

## Commit Result

```swift
public struct GitCommitResult: Hashable, Sendable, Codable {
    public var commitSHA: String
    public var branch: String
    public var newVersion: GitRemoteVersion?   // new file version for subsequent edits, nil after delete
    public var webURL: URL?
}
```

`newVersion` lets an editor keep saving without re-reading the file: GitHub returns the new blob SHA in the commit response; GitLab requires a follow-up HEAD/GET of the file to learn the new `last_commit_id` (providers must do this internally so `newVersion` is populated); Forgejo/Gitea return the new file SHA.

## Branch Creation

```swift
public struct GitCreateBranchRequest: Sendable {
    public var repository: GitRepositoryReference
    public var name: String
    public var fromRef: String   // branch name or commit SHA
}
```

## Branch Deletion

```swift
public struct GitDeleteBranchRequest: Sendable {
    public var repository: GitRepositoryReference
    public var name: String
}
```

## Repository Creation

```swift
public struct GitCreateRepositoryRequest: Sendable {
    public var name: String
    public var namespace: String?        // nil = user's personal namespace
    public var description: String?
    public var isPrivate: Bool
    public var initializeWithReadme: Bool
}
```

## Pull Request

Use one type for GitHub pull requests, GitLab merge requests, and Forgejo/Gitea pull requests. UI wording comes from `GitProvider.changeRequestTerm`.

```swift
public struct GitPullRequestRequest: Sendable {
    public var repository: GitRepositoryReference    // the repository the PR is opened on (upstream when forking)
    public var title: String
    public var body: String?
    public var sourceBranch: String
    public var sourceRepository: GitRepositoryReference?   // set when the source branch lives in a fork
    public var targetBranch: String
    public var draft: Bool
}
```

The normalized result:

```swift
public struct GitPullRequest: Hashable, Sendable, Codable {
    public var id: String
    public var number: Int?
    public var title: String
    public var webURL: URL
    public var sourceBranch: String
    public var targetBranch: String
    public var providerName: String
}
```
