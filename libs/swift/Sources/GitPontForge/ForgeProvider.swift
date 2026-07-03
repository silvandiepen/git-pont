import Foundation
import GitPontCore
import CryptoKit

/// Forgejo/Gitea provider implementation, including the Codeberg preset.
public struct ForgeProvider: GitProvider, GitAuthenticationProvider {
    public var kind: GitProviderKind { instances.first?.kind ?? .forgejo }
    public let displayName = "Forge"
    public let capabilities: GitProviderCapabilities = [.publicFileRead, .authenticatedFileRead, .fileCommit, .fileDelete, .directoryList, .branchCreate, .branchDelete, .repositoryCreate, .repositoryFork, .pullRequestCreate, .gitCLICredentials]
    public let changeRequestTerm: GitChangeRequestTerm = .pullRequest

    private let httpClient: any HTTPClient
    private let instances: [GitProviderInstance]
    private let oauth: OAuthAppConfig?
    private let decoder: JSONDecoder
    private let encoder: JSONEncoder

    public init(httpClient: any HTTPClient, instances: [GitProviderInstance] = [.codeberg], oauth: OAuthAppConfig? = nil) {
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
        guard segments.count >= 2 else { throw GitPontError.unsupportedURL(url.absoluteString) }
        if segments.count == 2 {
            return .resolved(GitURLReference(instance: instance, namespace: segments[0], name: stripGitSuffix(segments[1])))
        }
        guard segments.count >= 5 else { throw GitPontError.unsupportedURL(url.absoluteString) }
        if segments[2] == "src", segments[3] == "commit" {
            return .resolved(GitURLReference(instance: instance, namespace: segments[0], name: segments[1], ref: segments[4], path: segments.dropFirst(5).joined(separator: "/")))
        }
        if segments[2] == "src", segments[3] == "branch" {
            return parseRefPath(instance: instance, namespace: segments[0], name: segments[1], remainder: Array(segments.dropFirst(4)))
        }
        if segments[2] == "raw", segments[3] == "branch" {
            return parseRefPath(instance: instance, namespace: segments[0], name: segments[1], remainder: Array(segments.dropFirst(4)))
        }
        throw GitPontError.unsupportedURL(url.absoluteString)
    }

    public func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String] {
        switch authMethod {
        case .personalAccessToken:
            return ["Authorization": "token \(credential.accessToken)"]
        case .oauthDevice, .oauthPKCE:
            return ["Authorization": "Bearer \(credential.accessToken)"]
        }
    }

    public func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult {
        guard request.method == .oauthPKCE else {
            throw GitPontError.unsupportedCapability("Forgejo/Gitea supports browser OAuth")
        }
        let config = oauth ?? request.appConfig
        guard let redirectURI = config.redirectURI else {
            throw GitPontError.authenticationFailed("Forge OAuth redirect URI is required")
        }
        let state = randomOAuthString(byteCount: 32)
        let verifier = randomOAuthString(byteCount: 32)
        let authorizationURL = request.instance.baseURL
            .appendingPathComponent("login")
            .appendingPathComponent("oauth")
            .appendingPathComponent("authorize")
            .gitPontAppendingQuery([
                URLQueryItem(name: "client_id", value: config.clientID),
                URLQueryItem(name: "redirect_uri", value: redirectURI.absoluteString),
                URLQueryItem(name: "response_type", value: "code"),
                URLQueryItem(name: "scope", value: config.scopes.joined(separator: " ")),
                URLQueryItem(name: "state", value: state),
                URLQueryItem(name: "code_challenge", value: pkceChallenge(for: verifier)),
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
            throw GitPontError.unsupportedCapability("Forgejo/Gitea supports browser OAuth")
        }
        let config = oauth ?? request.appConfig
        let code = try authorizationCode(from: request.callbackURL, expectedState: request.state)
        guard let redirectURI = config.redirectURI else {
            throw GitPontError.authenticationFailed("Forge OAuth redirect URI is required")
        }
        var payload = [
            "client_id": config.clientID,
            "code": code,
            "grant_type": "authorization_code",
            "redirect_uri": redirectURI.absoluteString
        ]
        if let codeVerifier = request.codeVerifier {
            payload["code_verifier"] = codeVerifier
        }
        if let clientSecret = config.clientSecret {
            payload["client_secret"] = clientSecret
        }
        let response: ForgeOAuthTokenResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: request.instance.baseURL
                .appendingPathComponent("login")
                .appendingPathComponent("oauth")
                .appendingPathComponent("access_token"),
            headers: oauthHeaders,
            body: formEncodedBody(payload)
        ))
        return response.credential
    }

    public func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential {
        guard let refreshToken = credential.refreshToken else { return credential }
        guard let config = oauth else {
            throw GitPontError.unsupportedCapability("Forge OAuth refresh requires provider OAuth configuration")
        }
        var payload = [
            "client_id": config.clientID,
            "refresh_token": refreshToken,
            "grant_type": "refresh_token"
        ]
        if let clientSecret = config.clientSecret {
            payload["client_secret"] = clientSecret
        }
        let response: ForgeOAuthTokenResponse = try await sendOAuthJSON(HTTPRequest(
            method: "POST",
            url: instance.baseURL
                .appendingPathComponent("login")
                .appendingPathComponent("oauth")
                .appendingPathComponent("access_token"),
            headers: oauthHeaders,
            body: formEncodedBody(payload)
        ))
        return response.credential
    }

    public func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        let dto: ForgeUserDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: instance.apiBaseURL.appendingPathComponent("user"),
            headers: try authorizationHeaders(for: credential, authMethod: .personalAccessToken)
        ))
        return GitAccount(
            id: String(dto.id),
            login: dto.login,
            displayName: dto.fullName,
            avatarURL: dto.avatarURL,
            email: dto.email
        )
    }

    public func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        let connection = try context.requiredConnection
        let repos: [ForgeRepositoryDTO] = try await paginatedJSON(
            url: connection.instance.apiBaseURL
                .appendingPathComponent("user")
                .appendingPathComponent("repos")
                .gitPontAppendingQuery([
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "page", value: "1")
                ]),
            headers: try headers(for: context)
        )
        return GitList(items: repos.map { $0.repository(instance: connection.instance) }, truncated: repos.count >= 1500)
    }

    public func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        let dto: ForgeRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: repoURL(for: reference),
            headers: try headers(for: context)
        ))
        return dto.repository(instance: reference.instance)
    }

    public func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        let branches: [ForgeBranchDTO] = try await paginatedJSON(
            url: repoURL(for: repository).appendingPathComponent("branches"),
            headers: try headers(for: context)
        )
        return GitList(items: branches.map(\.branch), truncated: branches.count >= 1500)
    }

    public func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        let dto: ForgeContentDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: contentsURL(for: reference.repository, path: reference.path).gitPontAppendingQuery([
                URLQueryItem(name: "ref", value: reference.ref)
            ]),
            headers: try headers(for: context)
        ))
        guard dto.type == "file" else {
            throw GitPontError.unsupportedCapability("Forge content is not a file")
        }
        if let size = dto.size, size > 100_000_000 {
            throw GitPontError.fileTooLarge(size: size, limit: 100_000_000)
        }
        guard let content = dto.content else {
            throw GitPontError.invalidProviderResponse("Forge content is missing file data")
        }
        let normalizedContent = content.replacingOccurrences(of: "\n", with: "")
        guard let data = Data(base64Encoded: normalizedContent) else {
            throw GitPontError.invalidProviderResponse("Forge returned invalid Base64 content")
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
        let entries: [ForgeContentDTO] = try await sendJSON(HTTPRequest(
            method: "GET",
            url: contentsURL(for: reference.repository, path: reference.path).gitPontAppendingQuery([
                URLQueryItem(name: "ref", value: reference.ref)
            ]),
            headers: try headers(for: context)
        ))
        return GitList(items: entries.map(\.directoryEntry), truncated: false)
    }

    public func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        let method = change.expectedVersion == nil ? "POST" : "PUT"
        let payload = ForgeContentWriteRequest(
            branch: change.targetBranch,
            message: change.message,
            content: change.content.base64EncodedString(),
            sha: change.expectedVersion?.forgeSHA,
            author: forgeIdentity(name: change.authorName, email: change.authorEmail),
            committer: forgeIdentity(name: change.authorName, email: change.authorEmail)
        )
        let dto: ForgeContentWriteResponse
        do {
            dto = try await sendJSON(HTTPRequest(
                method: method,
                url: contentsURL(for: change.reference.repository, path: change.reference.path),
                headers: try headers(for: context),
                body: try encoder.encode(payload)
            ))
        } catch {
            throw populatedConflict(error, reference: change.reference, expectedVersion: change.expectedVersion)
        }
        return dto.commitResult(branch: change.targetBranch)
    }

    public func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        guard let sha = request.expectedVersion?.forgeSHA else {
            throw GitPontError.conflict(GitConflict(
                reference: request.reference,
                expectedVersion: request.expectedVersion,
                providerMessage: "Forge deletes require a blob SHA"
            ))
        }
        let payload = ForgeContentDeleteRequest(
            branch: request.targetBranch,
            message: request.message,
            sha: sha,
            author: forgeIdentity(name: request.authorName, email: request.authorEmail),
            committer: forgeIdentity(name: request.authorName, email: request.authorEmail)
        )
        let dto: ForgeContentWriteResponse
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
        return GitCommitResult(commitSHA: dto.commit.sha, branch: request.targetBranch, newVersion: nil, webURL: dto.commit.htmlURL)
    }

    public func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        _ = try context.requiredCredential
        let payload = ForgeCreateBranchRequest(newBranchName: request.name, oldRefName: request.fromRef)
        let dto: ForgeBranchDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repoURL(for: request.repository).appendingPathComponent("branches"),
            headers: try headers(for: context),
            body: try encoder.encode(payload)
        ))
        return dto.branch
    }

    public func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        _ = try context.requiredCredential
        let response = try await httpClient.send(HTTPRequest(
            method: "DELETE",
            url: repoURL(for: request.repository)
                .appendingPathComponent("branches")
                .gitPontAppendingEncodedPathComponent(request.name.addingPercentEncoding(withAllowedCharacters: .gitPontPathAllowed) ?? request.name),
            headers: try headers(for: context)
        ))
        try validate(response)
    }

    public func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        let connection = try context.requiredConnection
        _ = try context.requiredCredential
        let payload = ForgeCreateRepositoryRequest(
            name: request.name,
            description: request.description,
            private: request.isPrivate,
            autoInit: request.initializeWithReadme
        )
        let url: URL
        if let namespace = request.namespace {
            url = connection.instance.apiBaseURL
                .appendingPathComponent("orgs")
                .appendingPathComponent(namespace)
                .appendingPathComponent("repos")
        } else {
            url = connection.instance.apiBaseURL
                .appendingPathComponent("user")
                .appendingPathComponent("repos")
        }
        let dto: ForgeRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: url,
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
        let dto: ForgeRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repoURL(for: reference).appendingPathComponent("forks"),
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
        let payload = ForgePullRequestCreateRequest(
            title: request.title,
            body: request.body,
            head: head,
            base: request.targetBranch
        )
        let dto: ForgePullRequestDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repoURL(for: request.repository).appendingPathComponent("pulls"),
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

    private func repoURL(for reference: GitRepositoryReference) -> URL {
        reference.instance.apiBaseURL
            .appendingPathComponent("repos")
            .appendingPathComponent(reference.namespace)
            .appendingPathComponent(reference.name)
    }

    private func contentsURL(for repository: GitRepositoryReference, path: String) -> URL {
        repoURL(for: repository)
            .appendingPathComponent("contents")
            .appendingPathComponent(path)
    }

    private func existingFork(of reference: GitRepositoryReference, owner: String, context: GitProviderRequestContext) async throws -> GitRepository? {
        let forks: [ForgeRepositoryDTO] = try await paginatedJSON(
            url: repoURL(for: reference)
                .appendingPathComponent("forks")
                .gitPontAppendingQuery([
                    URLQueryItem(name: "limit", value: "50"),
                    URLQueryItem(name: "page", value: "1")
                ]),
            headers: try headers(for: context)
        )
        return forks.map { $0.repository(instance: reference.instance) }.first {
            $0.reference.namespace == owner && $0.reference.name == reference.name
        }
    }

    private func confirmedRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        do {
            return try await repository(reference, context: context)
        } catch GitPontError.unsupportedCapability {
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
            let nextPage = page + 1
            if let limit = url.gitPontQueryValue("limit"), items.count >= page * (Int(limit) ?? 50) {
                currentURL = url.gitPontReplacingQueryItem(name: "page", value: String(nextPage))
                page = nextPage
            } else {
                currentURL = nil
            }
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
            let error = try decoder.decode(ForgeOAuthErrorResponse.self, from: response.body)
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
        case 401:
            throw GitPontError.authenticationFailed("Forge authentication failed")
        case 403:
            throw GitPontError.permissionDenied("Forge permission denied")
        case 404:
            throw GitPontError.notFound("Forge resource not found")
        case 405:
            throw GitPontError.unsupportedCapability("Forge endpoint unavailable")
        case 409, 422:
            throw GitPontError.conflict(GitConflict(
                reference: GitFileReference(
                    repository: GitRepositoryReference(instance: .codeberg, namespace: "", name: ""),
                    path: "",
                    ref: ""
                ),
                providerMessage: "Forge conflict"
            ))
        case 429:
            throw GitPontError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        case 500..<600:
            throw GitPontError.providerUnavailable("Forge returned \(response.statusCode)")
        default:
            throw GitPontError.invalidProviderResponse("Forge returned \(response.statusCode)")
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

private struct ForgeUserDTO: Decodable {
    var id: Int
    var login: String
    var fullName: String?
    var avatarURL: URL?
    var email: String?

    enum CodingKeys: String, CodingKey {
        case id
        case login
        case fullName = "full_name"
        case avatarURL = "avatar_url"
        case email
    }
}

private struct ForgeRepositoryDTO: Decodable {
    var name: String
    var fullName: String
    var description: String?
    var `private`: Bool?
    var fork: Bool?
    var defaultBranch: String?
    var htmlURL: URL?
    var cloneURL: URL?
    var permissions: ForgePermissionsDTO?
    var parent: ForgeRepositoryReferenceDTO?
    var updatedAt: Date?

    enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case description
        case `private`
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
            isPrivate: `private` ?? false,
            isFork: fork ?? false,
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

private struct ForgeRepositoryReferenceDTO: Decodable {
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

private struct ForgePermissionsDTO: Decodable {
    var pull: Bool?
    var push: Bool?
    var admin: Bool?
}

private struct ForgeOAuthTokenResponse: Decodable {
    var accessToken: String
    var refreshToken: String?
    var tokenType: String?
    var expiresIn: TimeInterval?
    var scope: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case tokenType = "token_type"
        case expiresIn = "expires_in"
        case scope
    }

    var credential: GitCredential {
        GitCredential(
            accessToken: accessToken,
            refreshToken: refreshToken,
            tokenType: tokenType,
            expiresAt: expiresIn.map { Date().addingTimeInterval($0) },
            scopes: scope?.gitPontOAuthScopes ?? []
        )
    }
}

private struct ForgeOAuthErrorResponse: Decodable {
    var error: String?
    var errorDescription: String?

    enum CodingKeys: String, CodingKey {
        case error
        case errorDescription = "error_description"
    }
}

private struct ForgeBranchDTO: Decodable {
    var name: String
    var commit: ForgeCommitDTO
    var protected: Bool?

    var branch: GitBranch {
        GitBranch(name: name, commitSHA: commit.id ?? commit.sha ?? "", isProtected: protected ?? false)
    }
}

private struct ForgeCommitDTO: Decodable {
    var id: String?
    var sha: String?
}

private struct ForgeContentDTO: Decodable {
    var type: String
    var name: String
    var path: String
    var content: String?
    var sha: String?
    var size: Int?
    var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case type
        case name
        case path
        case content
        case sha
        case size
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

private struct ForgeContentWriteRequest: Encodable {
    var branch: String
    var message: String
    var content: String
    var sha: String?
    var author: ForgeIdentity?
    var committer: ForgeIdentity?
}

private struct ForgeContentDeleteRequest: Encodable {
    var branch: String
    var message: String
    var sha: String
    var author: ForgeIdentity?
    var committer: ForgeIdentity?
}

private struct ForgeIdentity: Encodable {
    var name: String
    var email: String
}

private func forgeIdentity(name: String?, email: String?) -> ForgeIdentity? {
    guard let name, let email else { return nil }
    return ForgeIdentity(name: name, email: email)
}

private struct ForgeContentWriteResponse: Decodable {
    var content: ForgeContentDTO?
    var commit: ForgeCommitResponseDTO

    func commitResult(branch: String) -> GitCommitResult {
        GitCommitResult(
            commitSHA: commit.sha,
            branch: branch,
            newVersion: content?.sha.map(GitRemoteVersion.blobSHA),
            webURL: commit.htmlURL
        )
    }
}

private struct ForgeCommitResponseDTO: Decodable {
    var sha: String
    var htmlURL: URL?

    enum CodingKeys: String, CodingKey {
        case sha
        case htmlURL = "html_url"
    }
}

private struct ForgeCreateBranchRequest: Encodable {
    var newBranchName: String
    var oldRefName: String

    enum CodingKeys: String, CodingKey {
        case newBranchName = "new_branch_name"
        case oldRefName = "old_ref_name"
    }
}

private struct ForgeCreateRepositoryRequest: Encodable {
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

private struct ForgePullRequestCreateRequest: Encodable {
    var title: String
    var body: String?
    var head: String
    var base: String
}

private struct ForgePullRequestDTO: Decodable {
    var id: Int
    var number: Int?
    var title: String
    var htmlURL: URL
    var head: ForgePullRequestBranchDTO
    var base: ForgePullRequestBranchDTO

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
            providerName: "Forge"
        )
    }
}

private struct ForgePullRequestBranchDTO: Decodable {
    var ref: String
}

private extension GitRemoteVersion {
    var forgeSHA: String? {
        if case .blobSHA(let sha) = self {
            return sha
        }
        return nil
    }
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

    func gitPontQueryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first(where: { $0.name == name })?
            .value
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
    static let gitPontPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()

    static let gitPontFormAllowed: CharacterSet = {
        var allowed = CharacterSet.urlQueryAllowed
        allowed.remove(charactersIn: ":#[]@!$&'()*+,;=")
        return allowed
    }()
}
