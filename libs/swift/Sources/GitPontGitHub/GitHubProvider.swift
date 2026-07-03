import Foundation
import GitPontCore

/// GitHub provider implementation for GitHub.com.
public struct GitHubProvider: GitProvider, GitAuthenticationProvider {
    public let kind: GitProviderKind = .github
    public let displayName = "GitHub"
    public let capabilities: GitProviderCapabilities = [
        .publicFileRead,
        .authenticatedFileRead,
        .fileCommit,
        .fileDelete,
        .directoryList,
        .branchCreate,
        .repositoryCreate,
        .repositoryFork,
        .pullRequestCreate,
        .gitCLICredentials,
        .branchDelete
    ]
    public let changeRequestTerm: GitChangeRequestTerm = .pullRequest

    private let httpClient: any HTTPClient
    private let oauth: OAuthAppConfig?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(httpClient: any HTTPClient, oauth: OAuthAppConfig? = nil) {
        self.httpClient = httpClient
        self.oauth = oauth
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func canHandle(url: URL) -> Bool {
        url.host?.lowercased() == "github.com" || url.host?.lowercased() == "raw.githubusercontent.com"
    }

    public func parse(url: URL) throws -> GitURLParseResult {
        let host = url.host?.lowercased()
        let segments = url.gitPontPathSegments
        if host == "github.com", segments.count >= 2 {
            if segments.count == 2 {
                return .resolved(GitURLReference(instance: .github, namespace: segments[0], name: stripGitSuffix(segments[1])))
            }
            if segments.count >= 5, segments[2] == "blob" || segments[2] == "tree" {
                return parseRefPath(instance: .github, namespace: segments[0], name: segments[1], remainder: Array(segments.dropFirst(3)))
            }
        }
        if host == "raw.githubusercontent.com", segments.count >= 4 {
            let remainder = Array(segments.dropFirst(2))
            return parseRefPath(instance: .github, namespace: segments[0], name: segments[1], remainder: remainder)
        }
        throw GitPontError.unsupportedURL(url.absoluteString)
    }

    public func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String] {
        ["Authorization": "Bearer \(credential.accessToken)"]
    }

    public func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult {
        guard request.method == .oauthDevice else {
            throw GitPontError.unsupportedCapability("GitHub v1 supports OAuth device flow")
        }
        let config = oauth ?? request.appConfig
        let response: GitHubDeviceCodeResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: URL(string: "https://github.com/login/device/code")!,
            headers: oauthHeaders,
            body: formEncodedBody([
                "client_id": config.clientID,
                "scope": config.scopes.joined(separator: " ")
            ])
        ))
        return .device(GitOAuthDeviceSession(
            verificationURI: response.verificationURI,
            userCode: response.userCode,
            deviceCode: response.deviceCode,
            interval: TimeInterval(response.interval ?? 5),
            expiresAt: Date().addingTimeInterval(TimeInterval(response.expiresIn))
        ))
    }

    public func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential {
        guard request.method == .oauthDevice else {
            throw GitPontError.unsupportedCapability("GitHub v1 supports OAuth device flow")
        }
        let config = oauth ?? request.appConfig
        guard let deviceCode = request.deviceCode else {
            throw GitPontError.authenticationFailed("GitHub OAuth device code is required")
        }
        let response: GitHubOAuthTokenResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            headers: oauthHeaders,
            body: formEncodedBody([
                "client_id": config.clientID,
                "device_code": deviceCode,
                "grant_type": "urn:ietf:params:oauth:grant-type:device_code"
            ])
        ))
        return response.credential(provider: .github)
    }

    public func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential {
        guard let refreshToken = credential.refreshToken else { return credential }
        let config = oauth ?? OAuthAppConfig(clientID: "", scopes: credential.scopes)
        guard !config.clientID.isEmpty else {
            throw GitPontError.unsupportedCapability("GitHub OAuth refresh requires an OAuth client ID")
        }
        var payload = [
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = config.clientSecret {
            payload["client_secret"] = clientSecret
        }
        let response: GitHubOAuthTokenResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: URL(string: "https://github.com/login/oauth/access_token")!,
            headers: oauthHeaders,
            body: formEncodedBody(payload)
        ))
        return response.credential(provider: .github)
    }

    public func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        let request = HTTPRequest(
            method: "GET",
            url: instance.apiBaseURL.appendingPathComponent("user"),
            headers: try authorizationHeaders(for: credential, authMethod: .personalAccessToken)
        )
        let dto: GitHubUserDTO = try await sendJSON(request)
        return GitAccount(
            id: String(dto.id),
            login: dto.login,
            displayName: dto.name,
            avatarURL: dto.avatarURL,
            email: dto.email
        )
    }

    public func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        let connection = try context.requiredConnection
        let credential = try context.requiredCredential
        let headers = try authorizationHeaders(for: credential, authMethod: connection.authMethod)
        let repos: [GitHubRepositoryDTO] = try await paginatedJSON(
            url: GitProviderInstance.github.apiBaseURL.appendingPathComponent("user/repos").gitPontAppendingQuery([
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "sort", value: "updated")
            ]),
            headers: headers
        )
        return GitList(items: repos.map { $0.repository(instance: .github) }, truncated: repos.count >= 3000)
    }

    public func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        let headers = try context.credential.map { try authorizationHeaders(for: $0, authMethod: context.connection?.authMethod ?? .personalAccessToken) } ?? [:]
        let url = GitProviderInstance.github.apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(reference.namespace)
            .appendingPathComponent(reference.name)
        let dto: GitHubRepositoryDTO = try await sendJSON(HTTPRequest(method: "GET", url: url, headers: headers))
        return dto.repository(instance: reference.instance)
    }

    public func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        let headers = try context.credential.map { try authorizationHeaders(for: $0, authMethod: context.connection?.authMethod ?? .personalAccessToken) } ?? [:]
        let url = GitProviderInstance.github.apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.namespace)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("branches")
            .gitPontAppendingQuery([URLQueryItem(name: "per_page", value: "100")])
        let branches: [GitHubBranchDTO] = try await paginatedJSON(url: url, headers: headers)
        return GitList(items: branches.map(\.branch), truncated: branches.count >= 3000)
    }
    public func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        let dto: GitHubContentDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: contentsURL(for: reference.repository, path: reference.path).gitPontAppendingQuery([
                URLQueryItem(name: "ref", value: reference.ref)
            ]),
            headers: try headers(for: context)
        ))
        guard dto.type == "file" else {
            throw GitPontError.unsupportedCapability("GitHub content is not a file")
        }
        if let size = dto.size, size > 100_000_000 {
            throw GitPontError.fileTooLarge(size: size, limit: 100_000_000)
        }
        guard dto.encoding == "base64", let content = dto.content else {
            throw GitPontError.fileTooLarge(size: dto.size, limit: 100_000_000)
        }
        let normalizedContent = content.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: normalizedContent) else {
            throw GitPontError.invalidProviderResponse("GitHub returned invalid Base64 content")
        }
        return GitRemoteFile(
            reference: reference,
            content: data,
            encoding: .binary,
            version: dto.sha.map(GitRemoteVersion.blobSHA),
            size: dto.size,
            lastCommitID: nil,
            etag: nil
        )
    }

    public func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        let entries: [GitHubContentDTO] = try await sendJSON(HTTPRequest(
            method: "GET",
            url: contentsURL(for: reference.repository, path: reference.path).gitPontAppendingQuery([
                URLQueryItem(name: "ref", value: reference.ref)
            ]),
            headers: try headers(for: context)
        ))
        return GitList(items: entries.map(\.directoryEntry), truncated: false)
    }

    public func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        let connection = try context.requiredConnection
        _ = try context.requiredCredential
        let payload = GitHubContentWriteRequest(
            message: change.message,
            content: change.content.base64EncodedString(),
            sha: change.expectedVersion?.githubSHA,
            branch: change.targetBranch,
            committer: gitHubIdentity(name: change.authorName, email: change.authorEmail),
            author: gitHubIdentity(name: change.authorName, email: change.authorEmail)
        )
        let dto: GitHubContentWriteResponse
        do {
            dto = try await sendJSON(HTTPRequest(
                method: "PUT",
                url: contentsURL(for: change.reference.repository, path: change.reference.path),
                headers: try headers(for: context),
                body: try encoder.encode(payload)
            ))
        } catch {
            throw populatedConflict(error, reference: change.reference, expectedVersion: change.expectedVersion)
        }
        _ = connection
        return dto.commitResult(branch: change.targetBranch)
    }

    public func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        guard let sha = request.expectedVersion?.githubSHA else {
            throw GitPontError.conflict(GitConflict(
                reference: request.reference,
                expectedVersion: request.expectedVersion,
                providerMessage: "GitHub deletes require a blob SHA"
            ))
        }
        let payload = GitHubContentDeleteRequest(
            message: request.message,
            sha: sha,
            branch: request.targetBranch,
            committer: gitHubIdentity(name: request.authorName, email: request.authorEmail),
            author: gitHubIdentity(name: request.authorName, email: request.authorEmail)
        )
        let dto: GitHubContentWriteResponse
        do {
            dto = try await sendJSON(HTTPRequest(
                method: "DELETE",
                url: contentsURL(for: request.reference.repository, path: request.reference.path),
                headers: try headers(for: context),
                body: try encoder.encode(payload)
            ))
        } catch {
            throw populatedConflict(error, reference: request.reference, expectedVersion: request.expectedVersion)
        }
        return GitCommitResult(
            commitSHA: dto.commit.sha,
            branch: request.targetBranch,
            newVersion: nil,
            webURL: dto.commit.htmlURL
        )
    }

    public func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        _ = try context.requiredCredential
        let sha: String
        if isHexRef(request.fromRef) {
            sha = request.fromRef
        } else {
            let ref: GitHubRefDTO = try await sendJSON(HTTPRequest(
                method: "GET",
                url: gitRefURL(for: request.repository, ref: "heads/\(request.fromRef)"),
                headers: try headers(for: context)
            ))
            sha = ref.object.sha
        }
        let payload = GitHubCreateRefRequest(ref: "refs/heads/\(request.name)", sha: sha)
        let created: GitHubRefDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: GitProviderInstance.github.apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(request.repository.namespace)
                .appendingPathComponent(request.repository.name)
                .appendingPathComponent("git/refs"),
            headers: try headers(for: context),
            body: try encoder.encode(payload)
        ))
        return GitBranch(name: request.name, commitSHA: created.object.sha)
    }

    public func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        _ = try context.requiredCredential
        let response = try await httpClient.send(HTTPRequest(
            method: "DELETE",
            url: gitRefURL(for: request.repository, ref: "heads/\(request.name)"),
            headers: try headers(for: context)
        ))
        try validate(response)
    }

    public func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        _ = try context.requiredCredential
        let payload = GitHubCreateRepositoryRequest(
            name: request.name,
            description: request.description,
            private: request.isPrivate,
            autoInit: request.initializeWithReadme
        )
        let url: URL
        if let namespace = request.namespace {
            url = GitProviderInstance.github.apiBaseURL
                .appendingPathComponent("orgs")
                .appendingPathComponent(namespace)
                .appendingPathComponent("repos")
        } else {
            url = GitProviderInstance.github.apiBaseURL.appendingPathComponent("user/repos")
        }
        let dto: GitHubRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: url,
            headers: try headers(for: context),
            body: try encoder.encode(payload)
        ))
        return dto.repository(instance: .github)
    }

    public func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        let connection = try context.requiredConnection
        _ = try context.requiredCredential
        if let existing = try await existingFork(of: reference, owner: connection.accountLogin, context: context) {
            return existing
        }
        let dto: GitHubRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: GitProviderInstance.github.apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(reference.namespace)
                .appendingPathComponent(reference.name)
                .appendingPathComponent("forks"),
            headers: try headers(for: context)
        ))
        return try await confirmedRepository(dto.repository(instance: reference.instance).reference, context: context)
    }

    public func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        _ = try context.requiredCredential
        let head: String
        if let sourceRepository = request.sourceRepository {
            head = "\(sourceRepository.namespace):\(request.sourceBranch)"
        } else {
            head = request.sourceBranch
        }
        let payload = GitHubPullRequestCreateRequest(
            title: request.title,
            body: request.body,
            head: head,
            base: request.targetBranch,
            draft: request.draft
        )
        let dto: GitHubPullRequestDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: GitProviderInstance.github.apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(request.repository.namespace)
                .appendingPathComponent(request.repository.name)
                .appendingPathComponent("pulls"),
            headers: try headers(for: context),
            body: try encoder.encode(payload)
        ))
        return dto.pullRequest
    }

    private func headers(for context: GitProviderRequestContext) throws -> [String: String] {
        guard let credential = context.credential else {
            return ["Accept": "application/vnd.github+json"]
        }
        var headers = try authorizationHeaders(for: credential, authMethod: context.connection?.authMethod ?? .personalAccessToken)
        headers["Accept"] = "application/vnd.github+json"
        return headers
    }

    private func contentsURL(for repository: GitRepositoryReference, path: String) -> URL {
        GitProviderInstance.github.apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.namespace)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("contents")
            .appendingPathComponent(path)
    }

    private func gitRefURL(for repository: GitRepositoryReference, ref: String) -> URL {
        GitProviderInstance.github.apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(repository.namespace)
            .appendingPathComponent(repository.name)
            .appendingPathComponent("git/ref")
            .appendingPathComponent(ref)
    }

    private func existingFork(of reference: GitRepositoryReference, owner: String, context: GitProviderRequestContext) async throws -> GitRepository? {
        let forks: [GitHubRepositoryDTO] = try await paginatedJSON(
            url: GitProviderInstance.github.apiBaseURL
                .appendingPathComponent("repos")
                .appendingPathComponent(reference.namespace)
                .appendingPathComponent(reference.name)
                .appendingPathComponent("forks")
                .gitPontAppendingQuery([URLQueryItem(name: "per_page", value: "100")]),
            headers: try headers(for: context)
        )
        return forks.map { $0.repository(instance: reference.instance) }.first {
            $0.reference.namespace == owner && $0.reference.name == reference.name
        }
    }

    private func confirmedRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        do {
            return try await repository(reference, context: context)
        } catch GitPontError.notFound {
            return GitRepository(
                reference: reference,
                isPrivate: false,
                isFork: true,
                permissions: GitRepositoryPermissions(canRead: true, canPush: true, canAdmin: false)
            )
        }
    }

    private func sendJSON<T: Decodable>(_ request: HTTPRequest) async throws -> T {
        let response = try await httpClient.send(request)
        try validate(response)
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw GitPontError.invalidProviderResponse(error.localizedDescription)
        }
    }

    private func paginatedJSON<T: Decodable>(url: URL, headers: [String: String]) async throws -> [T] {
        var nextURL: URL? = url
        var items: [T] = []
        var pages = 0

        while let currentURL = nextURL, pages < 30 {
            pages += 1
            let response = try await httpClient.send(HTTPRequest(method: "GET", url: currentURL, headers: headers))
            try validate(response)
            do {
                items.append(contentsOf: try decoder.decode([T].self, from: response.body))
            } catch {
                throw GitPontError.invalidProviderResponse(error.localizedDescription)
            }
            nextURL = response.gitPontNextLinkURL
        }

        return items
    }

    private var oauthHeaders: [String: String] {
        [
            "Accept": "application/json",
            "Content-Type": "application/x-www-form-urlencoded"
        ]
    }

    private func sendOAuthJSON<T: Decodable>(_ request: HTTPRequest) async throws -> T {
        let response = try await httpClient.send(request)
        do {
            let error = try decoder.decode(GitHubOAuthErrorResponse.self, from: response.body)
            throw GitPontError.authenticationFailed(error.errorDescription ?? error.error)
        } catch let gitPontError as GitPontError {
            throw gitPontError
        } catch {}
        try validate(response)
        do {
            return try decoder.decode(T.self, from: response.body)
        } catch {
            throw GitPontError.invalidProviderResponse(error.localizedDescription)
        }
    }

    private func populatedConflict(_ error: Error, reference: GitFileReference, expectedVersion: GitRemoteVersion?) -> Error {
        guard case GitPontError.conflict(let conflict) = error else {
            return error
        }
        return GitPontError.conflict(GitConflict(
            reference: reference,
            expectedVersion: expectedVersion,
            remoteVersion: conflict.remoteVersion,
            providerMessage: conflict.providerMessage
        ))
    }

    private func validate(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 401:
            throw GitPontError.authenticationFailed("GitHub authentication failed")
        case 403:
            throw GitPontError.permissionDenied("GitHub permission denied")
        case 404:
            throw GitPontError.notFound("GitHub resource not found")
        case 409, 422:
            throw GitPontError.conflict(GitConflict(
                reference: GitFileReference(
                    repository: GitRepositoryReference(instance: .github, namespace: "", name: ""),
                    path: "",
                    ref: ""
                ),
                providerMessage: "GitHub conflict"
            ))
        case 429:
            throw GitPontError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        case 500..<600:
            throw GitPontError.providerUnavailable("GitHub returned \(response.statusCode)")
        default:
            throw GitPontError.invalidProviderResponse("GitHub returned \(response.statusCode)")
        }
    }
}

private struct GitHubUserDTO: Decodable {
    var id: Int
    var login: String
    var name: String?
    var avatarURL: URL?
    var email: String?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case name
        case avatarURL = "avatar_url"
        case email
    }
}

private struct GitHubDeviceCodeResponse: Decodable {
    var deviceCode: String
    var userCode: String
    var verificationURI: URL
    var expiresIn: Int
    var interval: Int?

    enum CodingKeys: String, CodingKey {
        case deviceCode = "device_code"
        case userCode = "user_code"
        case verificationURI = "verification_uri"
        case expiresIn = "expires_in"
        case interval
    }
}

private struct GitHubOAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    var scope: String?
    var expiresIn: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
    }

    func credential(provider: GitProviderKind) -> GitCredential {
        GitCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            scopes: scope?.gitPontOAuthScopes ?? []
        )
    }
}

private struct GitHubOAuthErrorResponse: Decodable {
    var error: String
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct GitHubRepositoryDTO: Decodable {
    var name: String
    var fullName: String
    var description: String?
    var isPrivate: Bool
    var fork: Bool
    var defaultBranch: String?
    var htmlURL: URL?
    var cloneURL: URL?
    var permissions: GitHubPermissionsDTO?
    var parent: GitHubRepositoryReferenceDTO?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case description
        case isPrivate = "private"
        case fork
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
        case cloneURL = "clone_url"
        case permissions
        case parent
        case updatedAt = "updated_at"
    }

    func repository(instance: GitProviderInstance) -> GitRepository {
        GitRepository(
            reference: reference(instance: instance),
            description: description,
            isPrivate: isPrivate,
            isFork: fork,
            parent: parent?.reference(instance: instance),
            permissions: GitRepositoryPermissions(
                canRead: permissions?.pull ?? true,
                canPush: permissions?.push ?? false,
                canAdmin: permissions?.admin ?? false
            ),
            updatedAt: updatedAt
        )
    }

    func reference(instance: GitProviderInstance) -> GitRepositoryReference {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return GitRepositoryReference(
            instance: instance,
            namespace: parts.first ?? "",
            name: parts.count > 1 ? parts[1] : name,
            defaultBranch: defaultBranch,
            webURL: htmlURL,
            cloneHTTPSURL: cloneURL
        )
    }
}

private struct GitHubRepositoryReferenceDTO: Decodable {
    var name: String
    var fullName: String
    var defaultBranch: String?
    var htmlURL: URL?
    var cloneURL: URL?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case defaultBranch = "default_branch"
        case htmlURL = "html_url"
        case cloneURL = "clone_url"
    }

    func reference(instance: GitProviderInstance) -> GitRepositoryReference {
        let parts = fullName.split(separator: "/", maxSplits: 1).map(String.init)
        return GitRepositoryReference(
            instance: instance,
            namespace: parts.first ?? "",
            name: parts.count > 1 ? parts[1] : name,
            defaultBranch: defaultBranch,
            webURL: htmlURL,
            cloneHTTPSURL: cloneURL
        )
    }
}

private struct GitHubPermissionsDTO: Decodable {
    var pull: Bool?
    var push: Bool?
    var admin: Bool?
}

private struct GitHubBranchDTO: Decodable {
    var name: String
    var commit: GitHubCommitDTO
    var protected: Bool?

    var branch: GitBranch {
        GitBranch(name: name, commitSHA: commit.sha, isDefault: false, isProtected: protected ?? false)
    }
}

private struct GitHubCommitDTO: Decodable {
    var sha: String
}

private struct GitHubContentDTO: Decodable {
    var type: String
    var encoding: String?
    var size: Int?
    var name: String
    var path: String
    var content: String?
    var sha: String?
    var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case encoding
        case size
        case name
        case path
        case content
        case sha
        case htmlURL = "html_url"
    }

    var directoryEntry: GitDirectoryEntry {
        let entryType: GitDirectoryEntry.EntryType
        switch type {
        case "dir":
            entryType = .directory
        case "symlink":
            entryType = .symlink
        case "submodule":
            entryType = .submodule
        default:
            entryType = .file
        }
        return GitDirectoryEntry(name: name, path: path, type: entryType, size: size)
    }
}

private struct GitHubContentWriteRequest: Encodable {
    var message: String
    var content: String
    var sha: String?
    var branch: String
    var committer: GitHubIdentity?
    var author: GitHubIdentity?
}

private struct GitHubContentDeleteRequest: Encodable {
    var message: String
    var sha: String
    var branch: String
    var committer: GitHubIdentity?
    var author: GitHubIdentity?
}

private struct GitHubIdentity: Encodable {
    var name: String
    var email: String
}

private func gitHubIdentity(name: String?, email: String?) -> GitHubIdentity? {
    guard let name, let email else { return nil }
    return GitHubIdentity(name: name, email: email)
}

private struct GitHubContentWriteResponse: Decodable {
    var content: GitHubContentDTO?
    var commit: GitHubCommitResponseDTO

    func commitResult(branch: String) -> GitCommitResult {
        GitCommitResult(
            commitSHA: commit.sha,
            branch: branch,
            newVersion: content?.sha.map(GitRemoteVersion.blobSHA),
            webURL: commit.htmlURL
        )
    }
}

private struct GitHubCommitResponseDTO: Decodable {
    var sha: String
    var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case sha
        case htmlURL = "html_url"
    }
}

private struct GitHubRefDTO: Decodable {
    var ref: String
    var object: GitHubRefObjectDTO
}

private struct GitHubRefObjectDTO: Decodable {
    var sha: String
}

private struct GitHubCreateRefRequest: Encodable {
    var ref: String
    var sha: String
}

private struct GitHubCreateRepositoryRequest: Encodable {
    var name: String
    var description: String?
    var `private`: Bool
    var autoInit: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case `private`
        case autoInit = "auto_init"
    }
}

private struct GitHubPullRequestCreateRequest: Encodable {
    var title: String
    var body: String?
    var head: String
    var base: String
    var draft: Bool
}

private struct GitHubPullRequestDTO: Decodable {
    var id: Int
    var number: Int?
    var title: String
    var htmlURL: URL
    var head: GitHubPullRequestRefDTO
    var base: GitHubPullRequestRefDTO

    enum CodingKeys: String, CodingKey {
        case id
        case number
        case title
        case htmlURL = "html_url"
        case head
        case base
    }

    var pullRequest: GitPullRequest {
        GitPullRequest(
            id: String(id),
            number: number,
            title: title,
            webURL: htmlURL,
            sourceBranch: head.ref,
            targetBranch: base.ref,
            providerName: "GitHub"
        )
    }
}

private struct GitHubPullRequestRefDTO: Decodable {
    var ref: String
}

private extension GitRemoteVersion {
    var githubSHA: String? {
        if case .blobSHA(let sha) = self {
            return sha
        }
        return nil
    }
}

private func stripGitSuffix(_ value: String) -> String {
    value.hasSuffix(".git") ? String(value.dropLast(4)) : value
}

private func parseRefPath(instance: GitProviderInstance, namespace: String, name: String, remainder: [String]) -> GitURLParseResult {
    if let ref = remainder.first, isHexRef(ref) {
        return .resolved(GitURLReference(instance: instance, namespace: namespace, name: stripGitSuffix(name), ref: ref, path: remainder.dropFirst().joined(separator: "/")))
    }
    if remainder.count <= 2 {
        return .resolved(GitURLReference(instance: instance, namespace: namespace, name: stripGitSuffix(name), ref: remainder.first, path: remainder.dropFirst().joined(separator: "/")))
    }
    let candidates = (1..<remainder.count).reversed().map { split in
        GitURLReference(
            instance: instance,
            namespace: namespace,
            name: stripGitSuffix(name),
            ref: remainder.prefix(split).joined(separator: "/"),
            path: remainder.dropFirst(split).joined(separator: "/")
        )
    }
    return .ambiguous(candidates: candidates)
}

private func isHexRef(_ value: String) -> Bool {
    (7...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
}

private extension URL {
    func gitPontAppendingQuery(_ queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let existing = components?.queryItems ?? []
        components?.queryItems = existing + queryItems
        return components?.url ?? self
    }
}

private func formEncodedBody(_ fields: [String: String]) -> Data {
    fields
        .sorted { $0.key < $1.key }
        .map { "\($0.key.gitPontFormEncoded)=\($0.value.gitPontFormEncoded)" }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
}

private extension String {
    var gitPontFormEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .gitPontFormAllowed) ?? self
    }

    var gitPontOAuthScopes: [String] {
        split { $0 == "," || $0 == " " }
            .map(String.init)
            .filter { !$0.isEmpty }
    }
}

private extension CharacterSet {
    static let gitPontFormAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return allowed
    }()
}

private extension HTTPResponse {
    var gitPontNextLinkURL: URL? {
        guard let link = header("Link") else { return nil }
        let parts = link.split(separator: ",")
        for part in parts {
            let sections = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard sections.contains("rel=\"next\""), let first = sections.first else { continue }
            let value = first.trimmingCharacters(in: CharacterSet(charactersIn: "<>"))
            return URL(string: value)
        }
        return nil
    }
}
