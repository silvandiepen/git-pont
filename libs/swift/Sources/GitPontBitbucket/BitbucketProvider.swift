import Foundation
import GitPontCore

/// Bitbucket Cloud provider implementation.
public struct BitbucketProvider: GitProvider, GitAuthenticationProvider {
    public var kind: GitProviderKind { .bitbucketCloud }
    public let displayName = "Bitbucket"
    public let capabilities: GitProviderCapabilities = [.publicFileRead, .authenticatedFileRead, .fileCommit, .fileDelete, .directoryList, .branchCreate, .branchDelete, .repositoryCreate, .repositoryFork, .pullRequestCreate, .gitCLICredentials]
    public let changeRequestTerm: GitChangeRequestTerm = .pullRequest

    private let httpClient: any HTTPClient
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()

    public init(httpClient: any HTTPClient) {
        self.httpClient = httpClient
        decoder.dateDecodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
    }

    public func canHandle(url: URL) -> Bool {
        url.host?.lowercased() == GitProviderInstance.bitbucketCloud.baseURL.host
    }

    public func parse(url: URL) throws -> GitURLParseResult {
        let segments = url.gitPontPathSegments
        guard segments.count >= 2 else { throw GitPontError.unsupportedURL(url.absoluteString) }
        let workspace = segments[0]
        let repo = stripGitSuffix(segments[1])
        guard segments.count >= 5 else {
            return .resolved(GitURLReference(instance: .bitbucketCloud, namespace: workspace, name: repo))
        }
        guard segments[2] == "src" || segments[2] == "raw" else {
            throw GitPontError.unsupportedURL(url.absoluteString)
        }
        return parseRefPath(instance: .bitbucketCloud, namespace: workspace, name: repo, remainder: Array(segments.dropFirst(3)))
    }

    public func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String] {
        switch authMethod {
        case .personalAccessToken, .oauthDevice, .oauthPKCE:
            return ["Authorization": "Bearer \(credential.accessToken)"]
        }
    }

    public func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult {
        throw GitPontError.unsupportedCapability("Bitbucket OAuth is not configured")
    }

    public func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential {
        throw GitPontError.unsupportedCapability("Bitbucket OAuth is not configured")
    }

    public func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential {
        credential
    }

    public func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        let dto: BitbucketUserDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: instance.apiBaseURL.appendingPathComponent("user"),
            headers: try authorizationHeaders(for: credential, authMethod: .personalAccessToken)
        ))
        return GitAccount(id: dto.uuid ?? dto.accountID ?? dto.nickname, login: dto.nickname, displayName: dto.displayName, avatarURL: dto.links?.avatar?.href, email: nil)
    }

    public func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        let page: BitbucketPage<BitbucketRepositoryDTO> = try await paginatedJSON(
            url: GitProviderInstance.bitbucketCloud.apiBaseURL
                .appendingPathComponent("repositories")
                .gitPontAppendingQuery([
                    URLQueryItem(name: "role", value: "member"),
                    URLQueryItem(name: "pagelen", value: "100")
                ]),
            headers: try headers(for: context)
        )
        return GitList(items: page.values.map { $0.repository(instance: .bitbucketCloud) }, truncated: page.truncated)
    }

    public func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        let dto: BitbucketRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "GET",
            url: repositoryURL(reference),
            headers: try headers(for: context)
        ))
        return dto.repository(instance: reference.instance)
    }

    public func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        let page: BitbucketPage<BitbucketBranchDTO> = try await paginatedJSON(
            url: repositoryURL(repository)
                .appendingPathComponent("refs")
                .appendingPathComponent("branches")
                .gitPontAppendingQuery([URLQueryItem(name: "pagelen", value: "100")]),
            headers: try headers(for: context)
        )
        return GitList(items: page.values.map(\.branch), truncated: page.truncated)
    }

    public func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        let response = try await httpClient.send(HTTPRequest(
            method: "GET",
            url: sourceURL(reference),
            headers: try headers(for: context)
        ))
        try validate(response)
        let version = try await latestFileCommit(reference, context: context)
        return GitRemoteFile(
            reference: reference,
            content: response.body,
            encoding: .binary,
            version: version.map(GitRemoteVersion.commitID),
            size: response.body.count,
            lastCommitID: version,
            etag: response.header("ETag")
        )
    }

    public func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        let page: BitbucketPage<BitbucketSourceEntryDTO> = try await paginatedJSON(
            url: sourceURL(reference).gitPontAppendingQuery([URLQueryItem(name: "pagelen", value: "100")]),
            headers: try headers(for: context)
        )
        return GitList(items: page.values.map(\.directoryEntry), truncated: page.truncated)
    }

    public func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        let response: BitbucketCommitDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repositoryURL(change.reference.repository).appendingPathComponent("src"),
            headers: try headers(for: context, contentType: "multipart/form-data; boundary=\(multipartBoundary)"),
            body: multipartBody(fields: commitFields(
                message: change.message,
                branch: change.targetBranch,
                baseBranch: change.baseBranch,
                expectedVersion: change.expectedVersion,
                authorName: change.authorName,
                authorEmail: change.authorEmail
            ), files: [change.reference.path: change.content])
        ))
        let refreshed = try await readFile(
            GitFileReference(repository: change.reference.repository, path: change.reference.path, ref: change.targetBranch, webURL: change.reference.webURL),
            context: context
        )
        return GitCommitResult(commitSHA: response.hash, branch: change.targetBranch, newVersion: refreshed.version, webURL: response.links?.html?.href)
    }

    public func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        _ = try context.requiredCredential
        guard let expectedVersion = request.expectedVersion?.commitID else {
            throw GitPontError.conflict(GitConflict(reference: request.reference, expectedVersion: request.expectedVersion, providerMessage: "Bitbucket deletes require a commit ID"))
        }
        var fields = commitFields(message: request.message, branch: request.targetBranch, baseBranch: nil, expectedVersion: .commitID(expectedVersion), authorName: request.authorName, authorEmail: request.authorEmail)
        fields.append(("files", request.reference.path))
        let response: BitbucketCommitDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repositoryURL(request.reference.repository).appendingPathComponent("src"),
            headers: try headers(for: context, contentType: "multipart/form-data; boundary=\(multipartBoundary)"),
            body: multipartBody(fields: fields, files: [:])
        ))
        return GitCommitResult(commitSHA: response.hash, branch: request.targetBranch, newVersion: nil, webURL: response.links?.html?.href)
    }

    public func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        _ = try context.requiredCredential
        let payload = BitbucketBranchCreateRequest(name: request.name, target: BitbucketHashDTO(hash: request.fromRef))
        let dto: BitbucketBranchDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repositoryURL(request.repository).appendingPathComponent("refs").appendingPathComponent("branches"),
            headers: try headers(for: context, contentType: "application/json"),
            body: try encoder.encode(payload)
        ))
        return dto.branch
    }

    public func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        _ = try context.requiredCredential
        let response = try await httpClient.send(HTTPRequest(
            method: "DELETE",
            url: repositoryURL(request.repository)
                .appendingPathComponent("refs")
                .appendingPathComponent("branches")
                .gitPontAppendingEncodedPathComponent(request.name.gitPontPathEncoded),
            headers: try headers(for: context)
        ))
        try validate(response)
    }

    public func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        let connection = try context.requiredConnection
        _ = try context.requiredCredential
        let workspace = request.namespace ?? connection.accountLogin
        let payload = BitbucketRepositoryCreateRequest(scm: "git", isPrivate: request.isPrivate, description: request.description)
        let dto: BitbucketRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: connection.instance.apiBaseURL
                .appendingPathComponent("repositories")
                .appendingPathComponent(workspace)
                .appendingPathComponent(request.name),
            headers: try headers(for: context, contentType: "application/json"),
            body: try encoder.encode(payload)
        ))
        return dto.repository(instance: connection.instance)
    }

    public func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        _ = try context.requiredCredential
        let connection = try context.requiredConnection
        if let existing = try await existingFork(of: reference, owner: connection.accountLogin, context: context) {
            return existing
        }
        let dto: BitbucketRepositoryDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repositoryURL(reference).appendingPathComponent("forks"),
            headers: try headers(for: context, contentType: "application/json"),
            body: try encoder.encode(BitbucketForkRequest(workspace: BitbucketWorkspaceDTO(slug: connection.accountLogin)))
        ))
        return dto.repository(instance: reference.instance)
    }

    public func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        _ = try context.requiredCredential
        let payload = BitbucketPullRequestCreateRequest(
            title: request.draft && !request.title.hasPrefix("Draft: ") ? "Draft: \(request.title)" : request.title,
            description: request.body,
            source: BitbucketPullRequestEndpoint(branch: BitbucketNamedBranch(name: request.sourceBranch), repository: request.sourceRepository.map(BitbucketPullRequestRepository.init(reference:))),
            destination: BitbucketPullRequestEndpoint(branch: BitbucketNamedBranch(name: request.targetBranch), repository: BitbucketPullRequestRepository(reference: request.repository))
        )
        let dto: BitbucketPullRequestDTO = try await sendJSON(HTTPRequest(
            method: "POST",
            url: repositoryURL(request.repository).appendingPathComponent("pullrequests"),
            headers: try headers(for: context, contentType: "application/json"),
            body: try encoder.encode(payload)
        ))
        return dto.pullRequest
    }

    public func findPullRequest(_ query: GitPullRequestQuery, context: GitProviderRequestContext) async throws -> GitPullRequest? {
        _ = try context.requiredCredential
        let page: BitbucketPage<BitbucketPullRequestDTO> = try await paginatedJSON(
            url: repositoryURL(query.repository)
                .appendingPathComponent("pullrequests")
                .gitPontAppendingQuery([
                    URLQueryItem(name: "state", value: "OPEN"),
                    URLQueryItem(name: "pagelen", value: "10")
                ]),
            headers: try headers(for: context)
        )
        return page.values.first {
            $0.source?.branch.name == query.sourceBranch && $0.destination?.branch.name == query.targetBranch
        }?.pullRequest
    }

    private func headers(for context: GitProviderRequestContext, contentType: String? = nil) throws -> [String: String] {
        var headers: [String: String] = ["Accept": "application/json"]
        if let credential = context.credential {
            headers.merge(try authorizationHeaders(for: credential, authMethod: context.connection?.authMethod ?? .personalAccessToken)) { _, new in new }
        }
        if let contentType {
            headers["Content-Type"] = contentType
        }
        return headers
    }

    private func repositoryURL(_ reference: GitRepositoryReference) -> URL {
        reference.instance.apiBaseURL
            .appendingPathComponent("repositories")
            .appendingPathComponent(reference.namespace)
            .appendingPathComponent(reference.name)
    }

    private func sourceURL(_ reference: GitFileReference) -> URL {
        repositoryURL(reference.repository)
            .appendingPathComponent("src")
            .gitPontAppendingEncodedPathComponent(reference.ref.gitPontPathEncoded)
            .gitPontAppendingEncodedPathComponent(reference.path.gitPontPathEncoded)
    }

    private func latestFileCommit(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> String? {
        let page: BitbucketPage<BitbucketFileHistoryDTO> = try await sendJSON(HTTPRequest(
            method: "GET",
            url: repositoryURL(reference.repository)
                .appendingPathComponent("filehistory")
                .gitPontAppendingEncodedPathComponent(reference.ref.gitPontPathEncoded)
                .gitPontAppendingEncodedPathComponent(reference.path.gitPontPathEncoded)
                .gitPontAppendingQuery([URLQueryItem(name: "pagelen", value: "1")]),
            headers: try headers(for: context)
        ))
        return page.values.first?.commit?.hash
    }

    private func commitFields(message: String, branch: String, baseBranch: String?, expectedVersion: GitRemoteVersion?, authorName: String?, authorEmail: String?) -> [(String, String)] {
        var fields = [
            ("message", message),
            ("branch", branch)
        ]
        if let baseBranch {
            fields.append(("branch", baseBranch))
        }
        if let expectedVersion = expectedVersion?.commitID {
            fields.append(("parents", expectedVersion))
        }
        if let authorName, let authorEmail {
            fields.append(("author", "\(authorName) <\(authorEmail)>"))
        }
        return fields
    }

    private func existingFork(of reference: GitRepositoryReference, owner: String, context: GitProviderRequestContext) async throws -> GitRepository? {
        let page: BitbucketPage<BitbucketRepositoryDTO> = try await paginatedJSON(
            url: repositoryURL(reference).appendingPathComponent("forks").gitPontAppendingQuery([URLQueryItem(name: "pagelen", value: "100")]),
            headers: try headers(for: context)
        )
        return page.values.map { $0.repository(instance: reference.instance) }.first {
            $0.reference.namespace == owner && $0.reference.name == reference.name
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

    private func paginatedJSON<T: Decodable>(url: URL, headers: [String: String]) async throws -> BitbucketPage<T> {
        var currentURL: URL? = url
        var pageCount = 0
        var values: [T] = []
        var truncated = false
        while let url = currentURL, pageCount < 30 {
            let page: BitbucketPage<T> = try await sendJSON(HTTPRequest(method: "GET", url: url, headers: headers))
            values.append(contentsOf: page.values)
            currentURL = page.next
            pageCount += 1
        }
        if currentURL != nil {
            truncated = true
        }
        return BitbucketPage(values: values, next: nil, truncated: truncated)
    }

    private func validate(_ response: HTTPResponse) throws {
        switch response.statusCode {
        case 200..<300:
            return
        case 400, 409:
            throw GitPontError.conflict(GitConflict(reference: GitFileReference(repository: GitRepositoryReference(instance: .bitbucketCloud, namespace: "", name: ""), path: "", ref: ""), providerMessage: "Bitbucket conflict"))
        case 401:
            throw GitPontError.authenticationFailed("Bitbucket authentication failed")
        case 403:
            throw GitPontError.permissionDenied("Bitbucket permission denied")
        case 404:
            throw GitPontError.notFound("Bitbucket resource not found")
        case 429:
            throw GitPontError.rateLimited(retryAfter: response.header("Retry-After").flatMap(TimeInterval.init))
        case 500..<600:
            throw GitPontError.providerUnavailable("Bitbucket returned \(response.statusCode)")
        default:
            throw GitPontError.invalidProviderResponse("Bitbucket returned \(response.statusCode)")
        }
    }
}

private let multipartBoundary = "GitPontBoundary7MA4YWxkTrZu0gW"

private func multipartBody(fields: [(String, String)], files: [String: Data]) -> Data {
    var data = Data()
    for (name, value) in fields {
        data.append("--\(multipartBoundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(name)\"\r\n\r\n")
        data.append("\(value)\r\n")
    }
    for (path, content) in files {
        data.append("--\(multipartBoundary)\r\n")
        data.append("Content-Disposition: form-data; name=\"\(path)\"; filename=\"\(path.split(separator: "/").last ?? "file")\"\r\n")
        data.append("Content-Type: application/octet-stream\r\n\r\n")
        data.append(content)
        data.append("\r\n")
    }
    data.append("--\(multipartBoundary)--\r\n")
    return data
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

private struct BitbucketPage<T: Decodable>: Decodable {
    var values: [T]
    var next: URL?
    var truncated: Bool

    init(values: [T], next: URL?, truncated: Bool = false) {
        self.values = values
        self.next = next
        self.truncated = truncated
    }

    enum CodingKeys: String, CodingKey {
        case values
        case next
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.values = try container.decodeIfPresent([T].self, forKey: .values) ?? []
        self.next = try container.decodeIfPresent(URL.self, forKey: .next)
        self.truncated = false
    }
}

private struct BitbucketUserDTO: Decodable {
    var uuid: String?
    var accountID: String?
    var nickname: String
    var displayName: String?
    var links: BitbucketLinksDTO?

    enum CodingKeys: String, CodingKey {
        case uuid
        case accountID = "account_id"
        case nickname
        case displayName = "display_name"
        case links
    }
}

private struct BitbucketRepositoryDTO: Decodable {
    var uuid: String?
    var slug: String
    var name: String?
    var fullName: String
    var description: String?
    var isPrivate: Bool?
    var parent: BitbucketRepositorySummaryDTO?
    var mainbranch: BitbucketNamedBranch?
    var links: BitbucketLinksDTO?
    var updatedOn: Date?

    enum CodingKeys: String, CodingKey {
        case uuid
        case slug
        case name
        case fullName = "full_name"
        case description
        case isPrivate = "is_private"
        case parent
        case mainbranch
        case links
        case updatedOn = "updated_on"
    }

    func repository(instance: GitProviderInstance) -> GitRepository {
        let namespace = fullName.split(separator: "/").dropLast().joined(separator: "/")
        let parentReference = parent?.reference(instance: instance)
        return GitRepository(
            reference: GitRepositoryReference(
                instance: instance,
                namespace: namespace,
                name: slug,
                defaultBranch: mainbranch?.name,
                webURL: links?.html?.href,
                cloneHTTPSURL: links?.clone?.first(where: { $0.name == "https" })?.href
            ),
            description: description,
            isPrivate: isPrivate ?? true,
            isFork: parentReference != nil,
            parent: parentReference,
            permissions: GitRepositoryPermissions(canRead: true, canPush: true, canAdmin: false),
            updatedAt: updatedOn
        )
    }
}

private struct BitbucketRepositorySummaryDTO: Decodable {
    var fullName: String
    var slug: String?
    var links: BitbucketLinksDTO?

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
        case slug
        case links
    }

    func reference(instance: GitProviderInstance) -> GitRepositoryReference {
        let parts = fullName.split(separator: "/").map(String.init)
        return GitRepositoryReference(instance: instance, namespace: parts.dropLast().joined(separator: "/"), name: slug ?? parts.last ?? "", webURL: links?.html?.href)
    }
}

private struct BitbucketBranchDTO: Decodable {
    var name: String
    var target: BitbucketHashDTO

    var branch: GitBranch {
        GitBranch(name: name, commitSHA: target.hash, isDefault: false, isProtected: false)
    }
}

private struct BitbucketHashDTO: Codable {
    var hash: String
}

private struct BitbucketSourceEntryDTO: Decodable {
    var path: String
    var type: String
    var size: Int?

    var directoryEntry: GitDirectoryEntry {
        let entryType: GitDirectoryEntry.EntryType = type == "commit_directory" ? .directory : .file
        return GitDirectoryEntry(name: path.split(separator: "/").last.map(String.init) ?? path, path: path, type: entryType, size: size)
    }
}

private struct BitbucketFileHistoryDTO: Decodable {
    var commit: BitbucketHashDTO?
}

private struct BitbucketCommitDTO: Decodable {
    var hash: String
    var links: BitbucketLinksDTO?
}

private struct BitbucketRepositoryCreateRequest: Encodable {
    var scm: String
    var isPrivate: Bool
    var description: String?

    enum CodingKeys: String, CodingKey {
        case scm
        case isPrivate = "is_private"
        case description
    }
}

private struct BitbucketBranchCreateRequest: Encodable {
    var name: String
    var target: BitbucketHashDTO
}

private struct BitbucketForkRequest: Encodable {
    var workspace: BitbucketWorkspaceDTO
}

private struct BitbucketWorkspaceDTO: Codable {
    var slug: String
}

private struct BitbucketPullRequestCreateRequest: Encodable {
    var title: String
    var description: String?
    var source: BitbucketPullRequestEndpoint
    var destination: BitbucketPullRequestEndpoint
}

private struct BitbucketPullRequestEndpoint: Codable {
    var branch: BitbucketNamedBranch
    var repository: BitbucketPullRequestRepository?
}

private struct BitbucketNamedBranch: Codable {
    var name: String
}

private struct BitbucketPullRequestRepository: Codable {
    var fullName: String

    enum CodingKeys: String, CodingKey {
        case fullName = "full_name"
    }

    init(reference: GitRepositoryReference) {
        self.fullName = "\(reference.namespace)/\(reference.name)"
    }
}

private struct BitbucketPullRequestDTO: Decodable {
    var id: Int
    var title: String
    var links: BitbucketLinksDTO?
    var source: BitbucketPullRequestEndpoint?
    var destination: BitbucketPullRequestEndpoint?

    var pullRequest: GitPullRequest {
        GitPullRequest(
            id: String(id),
            number: id,
            title: title,
            webURL: links?.html?.href ?? URL(string: "https://bitbucket.org")!,
            sourceBranch: source?.branch.name ?? "",
            targetBranch: destination?.branch.name ?? "",
            providerName: "Bitbucket"
        )
    }
}

private struct BitbucketLinksDTO: Decodable {
    var html: BitbucketLinkDTO?
    var avatar: BitbucketLinkDTO?
    var clone: [BitbucketCloneLinkDTO]?
}

private struct BitbucketLinkDTO: Decodable {
    var href: URL
}

private struct BitbucketCloneLinkDTO: Decodable {
    var name: String?
    var href: URL
}

private extension GitRemoteVersion {
    var commitID: String? {
        if case .commitID(let id) = self {
            return id
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

    func gitPontAppendingEncodedPathComponent(_ encodedComponent: String) -> URL {
        var components = URLComponents(url: self, resolvingAgainstBaseURL: false)
        let current = components?.percentEncodedPath ?? path
        let separator = current.hasSuffix("/") ? "" : "/"
        components?.percentEncodedPath = current + separator + encodedComponent
        return components?.url ?? self
    }
}

private extension String {
    var gitPontPathEncoded: String {
        addingPercentEncoding(withAllowedCharacters: .gitPontPathAllowed) ?? self
    }
}

private extension CharacterSet {
    static let gitPontPathAllowed: CharacterSet = {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "/")
        return allowed
    }()
}

private extension Data {
    mutating func append(_ value: String) {
        append(Data(value.utf8))
    }
}
