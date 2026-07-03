import Foundation
import GitPontCore
import CryptoKit

/// GitLab provider implementation for GitLab.com and configured self-hosted instances.
public struct GitLabProvider: GitProvider, GitAuthenticationProvider {
    public var kind: GitProviderKind { instances.first?.kind ?? .gitLabCloud }
    public let displayName = "GitLab"
    public let capabilities: GitProviderCapabilities = [.publicFileRead, .authenticatedFileRead, .fileCommit, .fileDelete, .directoryList, .branchCreate, .branchDelete, .repositoryCreate, .repositoryFork, .pullRequestCreate, .gitCLICredentials]
    public let changeRequestTerm: GitChangeRequestTerm = .mergeRequest

    private let httpClient: any HTTPClient
    private let instances: [GitProviderInstance]
    private let oauth: OAuthAppConfig?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(httpClient: any HTTPClient, instances: [GitProviderInstance] = [.gitLabCloud], oauth: OAuthAppConfig? = nil) {
        self.httpClient = httpClient
        self.instances = instances
        self.oauth = oauth
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.encoder = JSONEncoder()
        self.encoder.outputFormatting = [.sortedKeys]
    }

    public func canHandle(url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        return instances.contains { $0.baseURL.host?.lowercased() == host }
    }

    public func parse(url: URL) throws -> GitURLParseResult {
        guard let instance = instances.first(where: { $0.baseURL.host?.lowercased() == url.host?.lowercased() }) else {
            throw GitPontError.unsupportedURL(url.absoluteString)
        }
        let segments = url.gitPontPathSegments
        guard let marker = segments.firstIndex(of: "-") else {
            guard segments.count >= 2 else { throw GitPontError.unsupportedURL(url.absoluteString) }
            return .resolved(GitURLReference(instance: instance, namespace: segments.dropLast().joined(separator: "/"), name: stripGitSuffix(segments.last!)))
        }
        guard marker + 2 < segments.count, segments[marker + 1] == "blob" || segments[marker + 1] == "raw" || segments[marker + 1] == "tree" else {
            throw GitPontError.unsupportedURL(url.absoluteString)
        }
        let namespaceAndName = segments.prefix(marker)
        guard namespaceAndName.count >= 2 else { throw GitPontError.unsupportedURL(url.absoluteString) }
        let namespace = namespaceAndName.dropLast().joined(separator: "/")
        let name = namespaceAndName.last!
        return parseRefPath(instance: instance, namespace: namespace, name: name, remainder: Array(segments.dropFirst(marker + 2)))
    }

    public func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String] {
        switch authMethod {
        case .personalAccessToken:
            return ["PRIVATE-TOKEN": credential.accessToken]
        case .oauthDevice, .oauthPKCE:
            return ["Authorization": "Bearer \(credential.accessToken)"]
        }
    }

    public func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult {
        guard request.method == .oauthPKCE else {
            throw GitPontError.unsupportedCapability("GitLab supports OAuth PKCE")
        }
        let config = oauth ?? request.appConfig
        guard let redirectURI = config.redirectURI else {
            throw GitPontError.authenticationFailed("GitLab OAuth redirect URI is required")
        }
        let state = randomOAuthString(byteCount: 32)
        let verifier = randomOAuthString(byteCount: 32)
        let challenge = pkceChallenge(for: verifier)
        let authorizationURL = request.instance.baseURL
            .appendingPathComponent("oauth")
            .appendingPathComponent("authorize")
            .gitPontAppendingQuery([
                URLQueryItem(name: "client_id", value: config.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: challenge),
                URLQueryItem(name: "code_challenge_method", value: "S256")
            ])
        return .browser(GitOAuthBrowserSession(
            authorizationURL: authorizationURL,
            state: state,
            codeVerifier: verifier,
            redirectURI: redirectURI
        ))
    }

    public func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential {
        guard request.method == .oauthPKCE else {
            throw GitPontError.unsupportedCapability("GitLab supports OAuth PKCE")
        }
        let config = oauth ?? request.appConfig
        let code = try authorizationCode(from: request.callbackURL, expectedState: request.state)
        guard let redirectURI = config.redirectURI else {
            throw GitPontError.authenticationFailed("GitLab OAuth redirect URI is required")
        }
        guard let codeVerifier = request.codeVerifier else {
            throw GitPontError.authenticationFailed("GitLab OAuth code verifier is required")
        }
        var payload = [
            "client_id": config.clientID,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString,
            "code_verifier": codeVerifier
        ]
        if let clientSecret = config.clientSecret {
            payload["client_secret"] = clientSecret
        }
        let response: GitLabOAuthTokenResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: request.instance.baseURL.appendingPathComponent("oauth").appendingPathComponent("token"),
            headers: oauthHeaders,
            body: formEncodedBody(payload)
        ))
        return response.credential
    }

    public func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential {
        guard let refreshToken = credential.refreshToken else { return credential }
        guard let config = oauth else {
            throw GitPontError.unsupportedCapability("GitLab OAuth refresh requires provider OAuth configuration")
        }
        guard let redirectURI = config.redirectURI else {
            throw GitPontError.authenticationFailed("GitLab OAuth redirect URI is required")
        }
        var payload = [
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token",
            "redirect_uri": redirectURI.absoluteString
        ]
        if let clientSecret = config.clientSecret {
            payload["client_secret"] = clientSecret
        }
        let response: GitLabOAuthTokenResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: instance.baseURL.appendingPathComponent("oauth").appendingPathComponent("token"),
            headers: oauthHeaders,
            body: formEncodedBody(payload)
        ))
        return response.credential
    }

    public func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        let dto: GitLabUserDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: instance.apiBaseURL.appendingPathComponent("user"),
            headers: try authorizationHeaders(for: credential, authMethod: .personalAccessToken)
        ))
        return GitAccount(
            id: String(dto.id),
            login: dto.username,
            displayName: dto.name,
            avatarURL: dto.avatarURL,
            email: dto.email
        )
    }

    public func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        let connection = try context.requiredConnection
        let projects: [GitLabProjectDTO] = try await paginatedJSON(
            url: connection.instance.apiBaseURL.appendingPathComponent("projects").gitPontAppendingQuery([
                URLQueryItem(name: "membership", value: "true"),
                URLQueryItem(name: "per_page", value: "100"),
                URLQueryItem(name: "order_by", value: "last_activity_at")
            ]),
            headers: try headers(for: context)
        )
        return GitList(items: projects.map { $0.repository(instance: connection.instance) }, truncated: projects.count >= 3000)
    }

    public func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        let dto: GitLabProjectDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: reference.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: reference)),
            headers: try headers(for: context)
        ))
        return dto.repository(instance: reference.instance)
    }

    public func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        let branches: [GitLabBranchDTO] = try await paginatedJSON(
            url: repository.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: repository))
                .appendingPathComponent("repository")
                .appendingPathComponent("branches")
                .gitPontAppendingQuery([URLQueryItem(name: "per_page", value: "100")]),
            headers: try headers(for: context)
        )
        return GitList(items: branches.map(\.branch), truncated: branches.count >= 3000)
    }

    public func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        let dto: GitLabFileDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: fileURL(for: reference).gitPontAppendingQuery([URLQueryItem(name: "ref", value: reference.ref)]),
            headers: try headers(for: context)
        ))
        if dto.size > 100_000_000 {
            throw GitPontError.fileTooLarge(size: dto.size, limit: 100_000_000)
        }
        guard let data = Data(base64Encoded: dto.content.replacingOccurrences(of: "\n", with: "")) else {
            throw GitPontError.invalidProviderResponse("GitLab returned invalid Base64 content")
        }
        return GitRemoteFile(
            reference: reference,
            content: data,
            encoding: .binary,
            version: .commitID(dto.lastCommitID),
            size: dto.size,
            lastCommitID: dto.lastCommitID,
            etag: nil
        )
    }

    public func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        let entries: [GitLabTreeEntryDTO] = try await paginatedJSON(
            url: reference.repository.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: reference.repository))
                .appendingPathComponent("repository")
                .appendingPathComponent("tree")
                .gitPontAppendingQuery([
                    URLQueryItem(name: "path", value: reference.path),
                    URLQueryItem(name: "ref", value: reference.ref),
                    URLQueryItem(name: "per_page", value: "100")
                ]),
            headers: try headers(for: context)
        )
        return GitList(items: entries.map(\.directoryEntry), truncated: entries.count >= 3000)
    }

    public func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        let method = change.expectedVersion == nil ? "POST" : "PUT"
        let payload = GitLabFileWriteRequest(
            branch: change.targetBranch,
            commitMessage: change.message,
            content: change.content.base64EncodedString(),
            encoding: "base64",
            lastCommitID: change.expectedVersion?.gitLabCommitID,
            startBranch: change.baseBranch,
            authorName: change.authorName,
            authorEmail: change.authorEmail
        )
        let response: GitLabCommitResponseDTO
        do {
            response = try await sendJSON(HTTPRequest(
                method: method,
                url: fileURL(for: change.reference),
                headers: try headers(for: context),
                body: try encoder.encode(payload)
            ))
        } catch {
            throw populatedConflict(error, reference: change.reference, expectedVersion: change.expectedVersion)
        }
        let refreshed = try await readFile(
            GitFileReference(
                repository: change.reference.repository,
                path: change.reference.path,
                ref: change.targetBranch,
                webURL: change.reference.webURL
            ),
            context: context
        )
        return GitCommitResult(
            commitSHA: response.commitID,
            branch: change.targetBranch,
            newVersion: refreshed.version,
            webURL: nil
        )
    }

    public func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        guard let lastCommitID = request.expectedVersion?.gitLabCommitID else {
            throw GitPontError.conflict(GitConflict(
                reference: request.reference,
                expectedVersion: request.expectedVersion,
                providerMessage: "GitLab deletes require a commit ID"
            ))
        }
        let payload = GitLabFileDeleteRequest(
            branch: request.targetBranch,
            commitMessage: request.message,
            lastCommitID: lastCommitID,
            authorName: request.authorName,
            authorEmail: request.authorEmail
        )
        let response: GitLabCommitResponseDTO
        do {
            response = try await sendJSON(HTTPRequest(
                method: "DELETE",
                url: fileURL(for: request.reference),
                headers: try headers(for: context),
                body: try encoder.encode(payload)
            ))
        } catch {
            throw populatedConflict(error, reference: request.reference, expectedVersion: request.expectedVersion)
        }
        return GitCommitResult(commitSHA: response.commitID, branch: request.targetBranch, newVersion: nil, webURL: nil)
    }

    public func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        _ = try context.requiredCredential
        let dto: GitLabBranchDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: request.repository.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: request.repository))
                .appendingPathComponent("repository")
                .appendingPathComponent("branches")
                .gitPontAppendingQuery([
                    URLQueryItem(name: "branch", value: request.name),
                    URLQueryItem(name: "ref", value: request.fromRef)
                ]),
            headers: try headers(for: context)
        ))
        return dto.branch
    }

    public func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        _ = try context.requiredCredential
        let response = try await httpClient.send(HTTPRequest(
            method: "DELETE",
            url: request.repository.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: request.repository))
                .appendingPathComponent("repository")
                .appendingPathComponent("branches")
                .gitPontAppendingEncodedPathComponent(request.name.addingPercentEncoding(withAllowedCharacters: .gitLabPathAllowed) ?? request.name),
            headers: try headers(for: context)
        ))
        try validate(response)
    }

    public func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        let connection = try context.requiredConnection
        _ = try context.requiredCredential
        let payload = GitLabCreateProjectRequest(
            name: request.name,
            namespaceID: request.namespace.flatMap(Int.init),
            description: request.description,
            visibility: request.isPrivate ? "private" : "public",
            initializeWithReadme: request.initializeWithReadme
        )
        let dto: GitLabProjectDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: connection.instance.apiBaseURL.appendingPathComponent("projects"),
            headers: try headers(for: context),
            body: try encoder.encode(payload)
        ))
        return dto.repository(instance: connection.instance)
    }

    public func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        let connection = try context.requiredConnection
        _ = try context.requiredCredential
        if let existing = try await existingFork(of: reference, owner: connection.accountLogin, context: context) {
            return existing
        }
        let dto: GitLabProjectDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: reference.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: reference))
                .appendingPathComponent("fork"),
            headers: try headers(for: context)
        ))
        return try await confirmedRepository(dto.repository(instance: reference.instance).reference, context: context)
    }

    public func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        _ = try context.requiredCredential
        let title = request.draft && !request.title.hasPrefix("Draft: ") ? "Draft: \(request.title)" : request.title
        let payload = GitLabMergeRequestCreateRequest(
            sourceBranch: request.sourceBranch,
            targetBranch: request.targetBranch,
            title: title,
            description: request.body,
            targetProjectID: request.sourceRepository == nil ? nil : projectID(for: request.repository)
        )
        let callRepository = request.sourceRepository ?? request.repository
        let dto: GitLabMergeRequestDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: callRepository.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: callRepository))
                .appendingPathComponent("merge_requests"),
            headers: try headers(for: context),
            body: try encoder.encode(payload)
        ))
        return dto.pullRequest
    }

    private func headers(for context: GitProviderRequestContext) throws -> [String: String] {
        guard let credential = context.credential else {
            return [:]
        }
        return try authorizationHeaders(for: credential, authMethod: context.connection?.authMethod ?? .personalAccessToken)
    }

    private func fileURL(for reference: GitFileReference) -> URL {
        reference.repository.instance.apiBaseURL
            .appendingPathComponent("projects")
            .gitPontAppendingEncodedPathComponent(projectID(for: reference.repository))
            .appendingPathComponent("repository")
            .appendingPathComponent("files")
            .gitPontAppendingEncodedPathComponent(reference.path.addingPercentEncoding(withAllowedCharacters: .gitLabPathAllowed) ?? reference.path)
    }

    private func projectID(for reference: GitRepositoryReference) -> String {
        "\(reference.namespace)/\(reference.name)"
            .addingPercentEncoding(withAllowedCharacters: .gitLabPathAllowed) ?? "\(reference.namespace)%2F\(reference.name)"
    }

    private func existingFork(of reference: GitRepositoryReference, owner: String, context: GitProviderRequestContext) async throws -> GitRepository? {
        let forks: [GitLabProjectDTO] = try await paginatedJSON(
            url: reference.instance.apiBaseURL
                .appendingPathComponent("projects")
                .gitPontAppendingEncodedPathComponent(projectID(for: reference))
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
        var currentURL: URL? = url
        var page = 1
        var items: [T] = []

        while let url = currentURL, page <= 30 {
            let response = try await httpClient.send(HTTPRequest(method: "GET", url: url, headers: headers))
            try validate(response)
            do {
                items.append(contentsOf: try decoder.decode([T].self, from: response.body))
            } catch {
                throw GitPontError.invalidProviderResponse(error.localizedDescription)
            }

            guard let nextPage = response.header("x-next-page"), !nextPage.isEmpty else {
                currentURL = nil
                continue
            }
            currentURL = url.gitPontReplacingQueryItem(name: "page", value: nextPage)
            page += 1
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
            let error = try decoder.decode(GitLabOAuthErrorResponse.self, from: response.body)
            if let value = error.error {
                throw GitPontError.authenticationFailed(error.errorDescription ?? value)
            }
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
        case 400, 409:
            throw GitPontError.conflict(GitConflict(
                reference: GitFileReference(
                    repository: GitRepositoryReference(instance: .gitLabCloud, namespace: "", name: ""),
                    path: "",
                    ref: ""
                ),
                providerMessage: "GitLab conflict"
            ))
        case 401:
            throw GitPontError.authenticationFailed("GitLab authentication failed")
        case 403:
            throw GitPontError.permissionDenied("GitLab permission denied")
        case 404:
            throw GitPontError.notFound("GitLab resource not found")
        case 429:
            throw GitPontError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        case 500..<600:
            throw GitPontError.providerUnavailable("GitLab returned \(response.statusCode)")
        default:
            throw GitPontError.invalidProviderResponse("GitLab returned \(response.statusCode)")
        }
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
    return .ambiguous(candidates: (1..<remainder.count).reversed().map { split in
        GitURLReference(instance: instance, namespace: namespace, name: stripGitSuffix(name), ref: remainder.prefix(split).joined(separator: "/"), path: remainder.dropFirst(split).joined(separator: "/"))
    })
}

private func isHexRef(_ value: String) -> Bool {
    (7...64).contains(value.count) && value.allSatisfy(\.isHexDigit)
}

private struct GitLabUserDTO: Decodable {
    var id: Int
    var username: String
    var name: String?
    var avatarURL: URL?
    var email: String?

    enum CodingKeys: String, CodingKey {
        case id
        case username
        case name
        case avatarURL = "avatar_url"
        case email
    }
}

private struct GitLabProjectDTO: Decodable {
    var id: Int
    var path: String
    var pathWithNamespace: String
    var description: String?
    var visibility: String?
    var defaultBranch: String?
    var webURL: URL?
    var httpURLToRepo: URL?
    var permissions: GitLabPermissionsDTO?
    var forkedFromProject: GitLabProjectReferenceDTO?
    var lastActivityAt: Date?

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case pathWithNamespace = "path_with_namespace"
        case description
        case visibility
        case defaultBranch = "default_branch"
        case webURL = "web_url"
        case httpURLToRepo = "http_url_to_repo"
        case permissions
        case forkedFromProject = "forked_from_project"
        case lastActivityAt = "last_activity_at"
    }

    func repository(instance: GitProviderInstance) -> GitRepository {
        GitRepository(
            reference: reference(instance: instance),
            description: description,
            isPrivate: visibility != "public",
            isFork: forkedFromProject != nil,
            parent: forkedFromProject?.reference(instance: instance),
            permissions: permissions?.repositoryPermissions ?? GitRepositoryPermissions(canRead: true, canPush: false, canAdmin: false),
            updatedAt: lastActivityAt
        )
    }

    func reference(instance: GitProviderInstance) -> GitRepositoryReference {
        let parts = pathWithNamespace.split(separator: "/").map(String.init)
        return GitRepositoryReference(
            instance: instance,
            namespace: parts.dropLast().joined(separator: "/"),
            name: parts.last ?? path,
            defaultBranch: defaultBranch,
            webURL: webURL,
            cloneHTTPSURL: httpURLToRepo
        )
    }
}

private struct GitLabProjectReferenceDTO: Decodable {
    var id: Int?
    var path: String
    var pathWithNamespace: String
    var defaultBranch: String?
    var webURL: URL?
    var httpURLToRepo: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case path
        case pathWithNamespace = "path_with_namespace"
        case defaultBranch = "default_branch"
        case webURL = "web_url"
        case httpURLToRepo = "http_url_to_repo"
    }

    func reference(instance: GitProviderInstance) -> GitRepositoryReference {
        let parts = pathWithNamespace.split(separator: "/").map(String.init)
        return GitRepositoryReference(
            instance: instance,
            namespace: parts.dropLast().joined(separator: "/"),
            name: parts.last ?? path,
            defaultBranch: defaultBranch,
            webURL: webURL,
            cloneHTTPSURL: httpURLToRepo
        )
    }
}

private struct GitLabPermissionsDTO: Decodable {
    var projectAccess: GitLabAccessDTO?
    var groupAccess: GitLabAccessDTO?

    enum CodingKeys: String, CodingKey {
        case projectAccess = "project_access"
        case groupAccess = "group_access"
    }

    var repositoryPermissions: GitRepositoryPermissions {
        let level = max(projectAccess?.accessLevel ?? 0, groupAccess?.accessLevel ?? 0)
        return GitRepositoryPermissions(
            canRead: level >= 10,
            canPush: level >= 30,
            canAdmin: level >= 40
        )
    }
}

private struct GitLabAccessDTO: Decodable {
    var accessLevel: Int

    enum CodingKeys: String, CodingKey {
        case accessLevel = "access_level"
    }
}

private struct GitLabOAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    var expiresIn: TimeInterval?
    var scope: String?
    var createdAt: TimeInterval?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
        case createdAt = "created_at"
    }

    var credential: GitCredential {
        let baseDate = createdAt.map(Date.init(timeIntervalSince1970:)) ?? Date()
        return GitCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiresIn.map { baseDate.addingTimeInterval($0) },
            scopes: scope?.gitPontOAuthScopes ?? []
        )
    }
}

private struct GitLabOAuthErrorResponse: Decodable {
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct GitLabBranchDTO: Decodable {
    var name: String
    var commit: GitLabCommitDTO
    var protected: Bool?
    var defaultBranch: Bool?

    enum CodingKeys: String, CodingKey {
        case name
        case commit
        case protected
        case defaultBranch = "default"
    }

    var branch: GitBranch {
        GitBranch(
            name: name,
            commitSHA: commit.id,
            isDefault: defaultBranch ?? false,
            isProtected: protected ?? false
        )
    }
}

private struct GitLabCommitDTO: Decodable {
    var id: String
}

private struct GitLabFileDTO: Decodable {
    var filePath: String
    var content: String
    var lastCommitID: String
    var blobID: String?
    var size: Int

    enum CodingKeys: String, CodingKey {
        case filePath = "file_path"
        case content
        case lastCommitID = "last_commit_id"
        case blobID = "blob_id"
        case size
    }
}

private struct GitLabTreeEntryDTO: Decodable {
    var name: String
    var path: String
    var type: String

    var directoryEntry: GitDirectoryEntry {
        let entryType: GitDirectoryEntry.EntryType = type == "tree" ? .directory : .file
        return GitDirectoryEntry(name: name, path: path, type: entryType, size: nil)
    }
}

private struct GitLabFileWriteRequest: Encodable {
    var branch: String
    var commitMessage: String
    var content: String
    var encoding: String
    var lastCommitID: String?
    var startBranch: String?
    var authorName: String?
    var authorEmail: String?

    enum CodingKeys: String, CodingKey {
        case branch
        case commitMessage = "commit_message"
        case content
        case encoding
        case lastCommitID = "last_commit_id"
        case startBranch = "start_branch"
        case authorName = "author_name"
        case authorEmail = "author_email"
    }
}

private struct GitLabFileDeleteRequest: Encodable {
    var branch: String
    var commitMessage: String
    var lastCommitID: String
    var authorName: String?
    var authorEmail: String?

    enum CodingKeys: String, CodingKey {
        case branch
        case commitMessage = "commit_message"
        case lastCommitID = "last_commit_id"
        case authorName = "author_name"
        case authorEmail = "author_email"
    }
}

private struct GitLabCommitResponseDTO: Decodable {
    var commitID: String

    enum CodingKeys: String, CodingKey {
        case commitID = "commit_id"
    }
}

private struct GitLabCreateProjectRequest: Encodable {
    var name: String
    var namespaceID: Int?
    var description: String?
    var visibility: String
    var initializeWithReadme: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case namespaceID = "namespace_id"
        case description
        case visibility
        case initializeWithReadme = "initialize_with_readme"
    }
}

private struct GitLabMergeRequestCreateRequest: Encodable {
    var sourceBranch: String
    var targetBranch: String
    var title: String
    var description: String?
    var targetProjectID: String?

    enum CodingKeys: String, CodingKey {
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
        case title
        case description
        case targetProjectID = "target_project_id"
    }
}

private struct GitLabMergeRequestDTO: Decodable {
    var id: Int
    var iid: Int?
    var title: String
    var webURL: URL
    var sourceBranch: String
    var targetBranch: String

    enum CodingKeys: String, CodingKey {
        case id
        case iid
        case title
        case webURL = "web_url"
        case sourceBranch = "source_branch"
        case targetBranch = "target_branch"
    }

    var pullRequest: GitPullRequest {
        GitPullRequest(
            id: String(id),
            number: iid,
            title: title,
            webURL: webURL,
            sourceBranch: sourceBranch,
            targetBranch: targetBranch,
            providerName: "GitLab"
        )
    }
}

private extension GitRemoteVersion {
    var gitLabCommitID: String? {
        if case .commitID(let id) = self {
            return id
        }
        return nil
    }
}

private extension CharacterSet {
    static let gitLabPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()
}

private extension URL {
    func gitPontAppendingQuery(_ queryItems: [URLQueryItem]) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let existing = components?.queryItems ?? []
        components?.queryItems = existing + queryItems
        return components?.url ?? self
    }

    func gitPontReplacingQueryItem(name: String, value: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        var items = components?.queryItems ?? []
        items.removeAll { $0.name == name }
        items.append(URLQueryItem(name: name, value: value))
        components?.queryItems = items
        return components?.url ?? self
    }

    func gitPontAppendingEncodedPathComponent(_ encodedComponent: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let current = components?.percentEncodedPath ?? path
        let separator = current.hasSuffix("/") ? "" : "/"
        components?.percentEncodedPath = current + separator + encodedComponent
        return components?.url ?? self
    }
}

private func authorizationCode(from callbackURL: URL?, expectedState: String?) throws -> String {
    guard let callbackURL, let components = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
        throw GitPontError.authenticationFailed("OAuth callback URL is required")
    }
    let queryItems = components.queryItems ?? []
    if let error = queryItems.first(where: { $0.name == "error" })?.value {
        throw GitPontError.authenticationFailed(error)
    }
    if let expectedState {
        guard queryItems.first(where: { $0.name == "state" })?.value == expectedState else {
            throw GitPontError.authenticationFailed("OAuth state did not match")
        }
    }
    guard let code = queryItems.first(where: { $0.name == "code" })?.value, !code.isEmpty else {
        throw GitPontError.authenticationFailed("OAuth authorization code is missing")
    }
    return code
}

private func pkceChallenge(for verifier: String) -> String {
    let digest = SHA256.hash(data: Data(verifier.utf8))
    return Data(digest).gitPontBase64URLString
}

private func randomOAuthString(byteCount: Int) -> String {
    var generator = SystemRandomNumberGenerator()
    let bytes = (0..<byteCount).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
    return Data(bytes).gitPontBase64URLString
}

private func formEncodedBody(_ fields: [String: String]) -> Data {
    fields
        .sorted { $0.key < $1.key }
        .map { "\($0.key.gitPontFormEncoded)=\($0.value.gitPontFormEncoded)" }
        .joined(separator: "&")
        .data(using: .utf8) ?? Data()
}

private extension Data {
    var gitPontBase64URLString: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
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
