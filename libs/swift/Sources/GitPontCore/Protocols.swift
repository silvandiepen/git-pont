import Foundation

/// Capability flags advertised by a provider implementation.
public struct GitProviderCapabilities: OptionSet, Sendable {
    public let rawValue: Int

    public init(rawValue: Int) {
        self.rawValue = rawValue
    }

    public static let publicFileRead = GitProviderCapabilities(rawValue: 1 << 0)
    public static let authenticatedFileRead = GitProviderCapabilities(rawValue: 1 << 1)
    public static let fileCommit = GitProviderCapabilities(rawValue: 1 << 2)
    public static let fileDelete = GitProviderCapabilities(rawValue: 1 << 3)
    public static let batchCommit = GitProviderCapabilities(rawValue: 1 << 4)
    public static let directoryList = GitProviderCapabilities(rawValue: 1 << 5)
    public static let branchCreate = GitProviderCapabilities(rawValue: 1 << 6)
    public static let repositoryCreate = GitProviderCapabilities(rawValue: 1 << 7)
    public static let repositoryFork = GitProviderCapabilities(rawValue: 1 << 8)
    public static let pullRequestCreate = GitProviderCapabilities(rawValue: 1 << 9)
    public static let gitCLICredentials = GitProviderCapabilities(rawValue: 1 << 10)
    public static let branchDelete = GitProviderCapabilities(rawValue: 1 << 11)
}

/// Provider-specific wording for change request objects.
public enum GitChangeRequestTerm: String, Sendable, Codable {
    case pullRequest
    case mergeRequest
}

/// Provider contract for normalized repository, file, branch, fork, and PR operations.
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

/// Per-request connection and credential context resolved by the facade.
public struct GitProviderRequestContext: Sendable {
    public var connection: GitConnection?
    public var credential: GitCredential?

    public init(connection: GitConnection?, credential: GitCredential?) {
        self.connection = connection
        self.credential = credential
    }

    public var requiredConnection: GitConnection {
        get throws {
            guard let connection else {
                throw GitPontError.authenticationRequired
            }
            return connection
        }
    }

    public var requiredCredential: GitCredential {
        get throws {
            guard let credential else {
                throw GitPontError.authenticationRequired
            }
            return credential
        }
    }
}

/// Storage abstraction for provider credentials.
public protocol CredentialStore: Sendable {
    func save(_ credential: GitCredential, for connectionID: String) async throws
    func loadCredential(for connectionID: String) async throws -> GitCredential?
    func deleteCredential(for connectionID: String) async throws
}

/// Storage abstraction for provider connection metadata.
public protocol ConnectionStore: Sendable {
    func save(_ connection: GitConnection) async throws
    func connections() async throws -> [GitConnection]
    func connection(id: String) async throws -> GitConnection?
    func delete(id: String) async throws
}

/// Minimal HTTP request abstraction used by provider modules.
public struct HTTPRequest: Sendable {
    public var method: String
    public var url: URL
    public var headers: [String: String]
    public var body: Data?

    public init(method: String, url: URL, headers: [String: String] = [:], body: Data? = nil) {
        self.method = method
        self.url = url
        self.headers = headers
        self.body = body
    }
}

/// Minimal HTTP response abstraction returned by injected clients.
public struct HTTPResponse: Sendable {
    public var statusCode: Int
    public var headers: [String: String]
    public var body: Data

    public init(statusCode: Int, headers: [String: String] = [:], body: Data = Data()) {
        self.statusCode = statusCode
        self.headers = headers
        self.body = body
    }

    public func header(_ name: String) -> String? {
        headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
    }
}

/// HTTP transport abstraction used to keep provider modules testable.
public protocol HTTPClient: Sendable {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse
}

/// URLSession-backed HTTP client for app and opt-in live integration use.
public struct URLSessionHTTPClient: HTTPClient {
    public init() {}

    public func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        var urlRequest = URLRequest(url: request.url)
        urlRequest.httpMethod = request.method
        urlRequest.httpBody = request.body
        for (name, value) in request.headers {
            urlRequest.setValue(value, forHTTPHeaderField: name)
        }

        let (data, response) = try await URLSession.shared.data(for: urlRequest)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw GitPontError.invalidProviderResponse("Response was not HTTP")
        }

        var headers: [String: String] = [:]
        for (key, value) in httpResponse.allHeaderFields {
            guard let key = key as? String else { continue }
            headers[key] = String(describing: value)
        }

        return HTTPResponse(statusCode: httpResponse.statusCode, headers: headers, body: data)
    }
}

/// Provider contract for OAuth start, completion, and credential refresh.
public protocol GitAuthenticationProvider: Sendable {
    func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String]
    func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult
    func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential
    func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential
}
