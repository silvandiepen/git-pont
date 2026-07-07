import Foundation

/// Supported provider families.
public enum GitProviderKind: String, Hashable, Sendable, Codable {
    case github
    case gitLabCloud
    case gitLabSelfHosted
    case forgejo
    case gitea
    case bitbucketCloud
}

/// A concrete provider host and API endpoint.
public struct GitProviderInstance: Hashable, Sendable, Codable {
    public var id: String
    public var kind: GitProviderKind
    public var baseURL: URL
    public var apiBaseURL: URL
    public var displayName: String

    public init(id: String, kind: GitProviderKind, baseURL: URL, apiBaseURL: URL, displayName: String) {
        self.id = id
        self.kind = kind
        self.baseURL = baseURL
        self.apiBaseURL = apiBaseURL
        self.displayName = displayName
    }
}

public extension GitProviderInstance {
    static let github = GitProviderInstance(
        id: "github.com",
        kind: .github,
        baseURL: URL(string: "https://github.com")!,
        apiBaseURL: URL(string: "https://api.github.com")!,
        displayName: "GitHub"
    )

    static let gitLabCloud = GitProviderInstance(
        id: "gitlab.com",
        kind: .gitLabCloud,
        baseURL: URL(string: "https://gitlab.com")!,
        apiBaseURL: URL(string: "https://gitlab.com/api/v4")!,
        displayName: "GitLab.com"
    )

    static let codeberg = GitProviderInstance(
        id: "codeberg.org",
        kind: .forgejo,
        baseURL: URL(string: "https://codeberg.org")!,
        apiBaseURL: URL(string: "https://codeberg.org/api/v1")!,
        displayName: "Codeberg"
    )

    static let bitbucketCloud = GitProviderInstance(
        id: "bitbucket.org",
        kind: .bitbucketCloud,
        baseURL: URL(string: "https://bitbucket.org")!,
        apiBaseURL: URL(string: "https://api.bitbucket.org/2.0")!,
        displayName: "Bitbucket"
    )

    static func gitLabSelfHosted(baseURL: URL, displayName: String? = nil) -> GitProviderInstance {
        let normalized = baseURL.gitPontDirectoryURL
        return GitProviderInstance(
            id: normalized.absoluteString,
            kind: .gitLabSelfHosted,
            baseURL: normalized,
            apiBaseURL: normalized.appendingPathComponent("api/v4"),
            displayName: displayName ?? normalized.host ?? "GitLab"
        )
    }

    static func forgejo(baseURL: URL, displayName: String? = nil) -> GitProviderInstance {
        forgeInstance(kind: .forgejo, baseURL: baseURL, displayName: displayName ?? baseURL.host ?? "Forgejo")
    }

    static func gitea(baseURL: URL, displayName: String? = nil) -> GitProviderInstance {
        forgeInstance(kind: .gitea, baseURL: baseURL, displayName: displayName ?? baseURL.host ?? "Gitea")
    }

    private static func forgeInstance(kind: GitProviderKind, baseURL: URL, displayName: String) -> GitProviderInstance {
        let normalized = baseURL.gitPontDirectoryURL
        return GitProviderInstance(
            id: normalized.absoluteString,
            kind: kind,
            baseURL: normalized,
            apiBaseURL: normalized.appendingPathComponent("api/v1"),
            displayName: displayName
        )
    }
}

/// Current provider account metadata.
public struct GitAccount: Hashable, Sendable, Codable {
    public var id: String
    public var login: String
    public var displayName: String?
    public var avatarURL: URL?
    public var email: String?

    public init(id: String, login: String, displayName: String? = nil, avatarURL: URL? = nil, email: String? = nil) {
        self.id = id
        self.login = login
        self.displayName = displayName
        self.avatarURL = avatarURL
        self.email = email
    }
}

/// Authentication method used by a connection.
public enum GitAuthMethod: String, Hashable, Sendable, Codable {
    case oauthDevice
    case oauthPKCE
    case personalAccessToken
}

/// Stored connection metadata without secrets.
public struct GitConnection: Identifiable, Hashable, Sendable, Codable {
    public var id: String
    public var instance: GitProviderInstance
    public var accountID: String
    public var accountLogin: String
    public var displayName: String?
    public var authMethod: GitAuthMethod
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String, instance: GitProviderInstance, accountID: String, accountLogin: String, displayName: String? = nil, authMethod: GitAuthMethod, createdAt: Date, updatedAt: Date) {
        self.id = id
        self.instance = instance
        self.accountID = accountID
        self.accountLogin = accountLogin
        self.displayName = displayName
        self.authMethod = authMethod
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Stable reference to a repository on a provider instance.
public struct GitRepositoryReference: Hashable, Sendable, Codable {
    public var instance: GitProviderInstance
    public var namespace: String
    public var name: String
    public var defaultBranch: String?
    public var webURL: URL?
    public var cloneHTTPSURL: URL?

    public init(instance: GitProviderInstance, namespace: String, name: String, defaultBranch: String? = nil, webURL: URL? = nil, cloneHTTPSURL: URL? = nil) {
        self.instance = instance
        self.namespace = namespace
        self.name = name
        self.defaultBranch = defaultBranch
        self.webURL = webURL
        self.cloneHTTPSURL = cloneHTTPSURL
    }
}

/// Repository metadata including permissions used for submission strategy.
public struct GitRepository: Hashable, Sendable, Codable {
    public var reference: GitRepositoryReference
    public var description: String?
    public var isPrivate: Bool
    public var isFork: Bool
    public var parent: GitRepositoryReference?
    public var permissions: GitRepositoryPermissions
    public var updatedAt: Date?

    public init(reference: GitRepositoryReference, description: String? = nil, isPrivate: Bool, isFork: Bool, parent: GitRepositoryReference? = nil, permissions: GitRepositoryPermissions, updatedAt: Date? = nil) {
        self.reference = reference
        self.description = description
        self.isPrivate = isPrivate
        self.isFork = isFork
        self.parent = parent
        self.permissions = permissions
        self.updatedAt = updatedAt
    }
}

/// Normalized repository permissions for the connected account.
public struct GitRepositoryPermissions: Hashable, Sendable, Codable {
    public var canRead: Bool
    public var canPush: Bool
    public var canAdmin: Bool

    public init(canRead: Bool, canPush: Bool, canAdmin: Bool) {
        self.canRead = canRead
        self.canPush = canPush
        self.canAdmin = canAdmin
    }
}

/// Branch metadata.
public struct GitBranch: Hashable, Sendable, Codable {
    public var name: String
    public var commitSHA: String
    public var isDefault: Bool
    public var isProtected: Bool

    public init(name: String, commitSHA: String, isDefault: Bool = false, isProtected: Bool = false) {
        self.name = name
        self.commitSHA = commitSHA
        self.isDefault = isDefault
        self.isProtected = isProtected
    }
}

/// Reference to a file path at a repository ref.
public struct GitFileReference: Hashable, Sendable, Codable {
    public var repository: GitRepositoryReference
    public var path: String
    public var ref: String
    public var webURL: URL?

    public init(repository: GitRepositoryReference, path: String, ref: String, webURL: URL? = nil) {
        self.repository = repository
        self.path = path
        self.ref = ref
        self.webURL = webURL
    }
}

/// Parsed URL reference before or after branch ambiguity resolution.
public struct GitURLReference: Hashable, Sendable {
    public var instance: GitProviderInstance
    public var namespace: String
    public var name: String
    public var ref: String?
    public var path: String?

    public init(instance: GitProviderInstance, namespace: String, name: String, ref: String? = nil, path: String? = nil) {
        self.instance = instance
        self.namespace = namespace
        self.name = name
        self.ref = ref
        self.path = path
    }
}

/// Result of provider URL parsing.
public enum GitURLParseResult: Sendable {
    case resolved(GitURLReference)
    case ambiguous(candidates: [GitURLReference])
}

/// Remote file payload and version metadata.
public struct GitRemoteFile: Hashable, Sendable {
    public var reference: GitFileReference
    public var content: Data
    public var encoding: GitFileEncoding
    public var version: GitRemoteVersion?
    public var size: Int?
    public var lastCommitID: String?
    public var etag: String?

    public init(reference: GitFileReference, content: Data, encoding: GitFileEncoding, version: GitRemoteVersion? = nil, size: Int? = nil, lastCommitID: String? = nil, etag: String? = nil) {
        self.reference = reference
        self.content = content
        self.encoding = encoding
        self.version = version
        self.size = size
        self.lastCommitID = lastCommitID
        self.etag = etag
    }
}

/// Normalized file content encoding.
public enum GitFileEncoding: String, Hashable, Sendable, Codable {
    case utf8
    case binary
}

/// Provider-specific remote version identity.
public enum GitRemoteVersion: Hashable, Sendable, Codable {
    case blobSHA(String)
    case commitID(String)
    case opaque(provider: GitProviderKind, value: String)
}

/// Directory listing entry.
public struct GitDirectoryEntry: Hashable, Sendable, Codable {
    /// Directory entry kind.
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

    public init(name: String, path: String, type: EntryType, size: Int? = nil) {
        self.name = name
        self.path = path
        self.type = type
        self.size = size
    }
}

/// Request to create or update a repository file.
public struct GitFileChange: Sendable {
    public var reference: GitFileReference
    public var content: Data
    public var message: String
    public var targetBranch: String
    public var baseBranch: String?
    public var expectedVersion: GitRemoteVersion?
    public var allowBlindOverwrite: Bool
    public var authorName: String?
    public var authorEmail: String?

    public init(reference: GitFileReference, content: Data, message: String, targetBranch: String, baseBranch: String? = nil, expectedVersion: GitRemoteVersion? = nil, allowBlindOverwrite: Bool = false, authorName: String? = nil, authorEmail: String? = nil) {
        self.reference = reference
        self.content = content
        self.message = message
        self.targetBranch = targetBranch
        self.baseBranch = baseBranch
        self.expectedVersion = expectedVersion
        self.allowBlindOverwrite = allowBlindOverwrite
        self.authorName = authorName
        self.authorEmail = authorEmail
    }
}

/// Request to delete a repository file.
public struct GitFileDeleteRequest: Sendable {
    public var reference: GitFileReference
    public var message: String
    public var targetBranch: String
    public var expectedVersion: GitRemoteVersion?
    public var allowBlindOverwrite: Bool
    public var authorName: String?
    public var authorEmail: String?

    public init(reference: GitFileReference, message: String, targetBranch: String, expectedVersion: GitRemoteVersion? = nil, allowBlindOverwrite: Bool = false, authorName: String? = nil, authorEmail: String? = nil) {
        self.reference = reference
        self.message = message
        self.targetBranch = targetBranch
        self.expectedVersion = expectedVersion
        self.allowBlindOverwrite = allowBlindOverwrite
        self.authorName = authorName
        self.authorEmail = authorEmail
    }
}

/// Result of a file commit or delete.
public struct GitCommitResult: Hashable, Sendable, Codable {
    public var commitSHA: String
    public var branch: String
    public var newVersion: GitRemoteVersion?
    public var webURL: URL?

    public init(commitSHA: String, branch: String, newVersion: GitRemoteVersion? = nil, webURL: URL? = nil) {
        self.commitSHA = commitSHA
        self.branch = branch
        self.newVersion = newVersion
        self.webURL = webURL
    }
}

/// Request to create a branch from an existing ref.
public struct GitCreateBranchRequest: Sendable {
    public var repository: GitRepositoryReference
    public var name: String
    public var fromRef: String

    public init(repository: GitRepositoryReference, name: String, fromRef: String) {
        self.repository = repository
        self.name = name
        self.fromRef = fromRef
    }
}

/// Request to delete a branch ref.
public struct GitDeleteBranchRequest: Sendable {
    public var repository: GitRepositoryReference
    public var name: String

    public init(repository: GitRepositoryReference, name: String) {
        self.repository = repository
        self.name = name
    }
}

/// Request to create a repository.
public struct GitCreateRepositoryRequest: Sendable {
    public var name: String
    public var namespace: String?
    public var description: String?
    public var isPrivate: Bool
    public var initializeWithReadme: Bool

    public init(name: String, namespace: String? = nil, description: String? = nil, isPrivate: Bool = true, initializeWithReadme: Bool = false) {
        self.name = name
        self.namespace = namespace
        self.description = description
        self.isPrivate = isPrivate
        self.initializeWithReadme = initializeWithReadme
    }
}

/// Request to create a pull request or merge request.
public struct GitPullRequestRequest: Sendable {
    public var repository: GitRepositoryReference
    public var title: String
    public var body: String?
    public var sourceBranch: String
    public var sourceRepository: GitRepositoryReference?
    public var targetBranch: String
    public var draft: Bool

    public init(repository: GitRepositoryReference, title: String, body: String? = nil, sourceBranch: String, sourceRepository: GitRepositoryReference? = nil, targetBranch: String, draft: Bool = false) {
        self.repository = repository
        self.title = title
        self.body = body
        self.sourceBranch = sourceBranch
        self.sourceRepository = sourceRepository
        self.targetBranch = targetBranch
        self.draft = draft
    }
}

/// Query for an existing open pull request or merge request.
public struct GitPullRequestQuery: Sendable {
    public var repository: GitRepositoryReference
    public var sourceBranch: String
    public var sourceRepository: GitRepositoryReference?
    public var targetBranch: String

    public init(repository: GitRepositoryReference, sourceBranch: String, sourceRepository: GitRepositoryReference? = nil, targetBranch: String) {
        self.repository = repository
        self.sourceBranch = sourceBranch
        self.sourceRepository = sourceRepository
        self.targetBranch = targetBranch
    }
}

/// Provider-neutral pull request or merge request result.
public struct GitPullRequest: Hashable, Sendable, Codable {
    public var id: String
    public var number: Int?
    public var title: String
    public var webURL: URL
    public var sourceBranch: String
    public var targetBranch: String
    public var providerName: String

    public init(id: String, number: Int? = nil, title: String, webURL: URL, sourceBranch: String, targetBranch: String, providerName: String) {
        self.id = id
        self.number = number
        self.title = title
        self.webURL = webURL
        self.sourceBranch = sourceBranch
        self.targetBranch = targetBranch
        self.providerName = providerName
    }
}

/// High-level change submission request handled by the facade.
public struct GitChangeSubmission: Sendable {
    /// Strategy used by the facade to submit a change.
    public enum Strategy: Sendable {
        case directCommit
        case existingBranch(branchName: String)
        case branchAndPullRequest(branchName: String, title: String, body: String?, draft: Bool)
        case forkAndPullRequest(branchName: String, title: String, body: String?, draft: Bool)
        case automatic(branchName: String, title: String, body: String?, draft: Bool)
    }

    public var change: GitFileChange
    public var strategy: Strategy

    public init(change: GitFileChange, strategy: Strategy) {
        self.change = change
        self.strategy = strategy
    }
}

/// Result of a high-level change submission.
public struct GitChangeResult: Sendable {
    public var commit: GitCommitResult
    public var pullRequest: GitPullRequest?
    public var usedRepository: GitRepositoryReference
    public var usedBranch: String

    public init(commit: GitCommitResult, pullRequest: GitPullRequest? = nil, usedRepository: GitRepositoryReference, usedBranch: String) {
        self.commit = commit
        self.pullRequest = pullRequest
        self.usedRepository = usedRepository
        self.usedBranch = usedBranch
    }
}

/// List response with truncation metadata.
public struct GitList<Element: Sendable>: Sendable {
    public var items: [Element]
    public var truncated: Bool

    public init(items: [Element], truncated: Bool = false) {
        self.items = items
        self.truncated = truncated
    }
}
