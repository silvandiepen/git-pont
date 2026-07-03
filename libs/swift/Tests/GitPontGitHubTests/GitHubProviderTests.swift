import Foundation
import Testing
import GitPontCore
@testable import GitPontGitHub

@Suite("GitHubProvider")
struct GitHubProviderTests {
    @Test func parsesRepositoryURL() throws {
        let provider = GitHubProvider(httpClient: MockHTTPClient())
        let result = try provider.parse(url: URL(string: "https://github.com/owner/repo.git")!)

        guard case .resolved(let reference) = result else {
            Issue.record("Expected resolved reference")
            return
        }

        #expect(reference.instance == .github)
        #expect(reference.namespace == "owner")
        #expect(reference.name == "repo")
        #expect(reference.ref == nil)
    }

    @Test func slashedBranchURLProducesAmbiguousCandidates() throws {
        let provider = GitHubProvider(httpClient: MockHTTPClient())
        let result = try provider.parse(url: URL(string: "https://github.com/owner/repo/blob/feature/foo/doc.md")!)

        guard case .ambiguous(let candidates) = result else {
            Issue.record("Expected ambiguous reference")
            return
        }

        #expect(candidates.first?.ref == "feature/foo")
        #expect(candidates.first?.path == "doc.md")
    }

    @Test func accountLoadsCurrentUser() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"id":1,"login":"octocat","name":"Mona","avatar_url":"https://example.com/avatar.png","email":"mona@example.com"}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let account = try await provider.account(
            instance: .github,
            credential: GitCredential(accessToken: "secret-token")
        )

        #expect(account.id == "1")
        #expect(account.login == "octocat")
        let requests = await client.requests
        #expect(requests.first?.url.absoluteString == "https://api.github.com/user")
        #expect(requests.first?.headers["Authorization"] == "Bearer secret-token")
    }

    @Test func oauthDeviceStartPostsDeviceCodeRequest() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"device_code":"device","user_code":"USER-CODE","verification_uri":"https://github.com/login/device","expires_in":900,"interval":5}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let result = try await provider.startOAuth(GitOAuthStartRequest(
            instance: .github,
            method: .oauthDevice,
            appConfig: OAuthAppConfig(clientID: "client-id", scopes: ["repo", "read:user"])
        ))

        guard case .device(let session) = result else {
            Issue.record("Expected device session")
            return
        }
        #expect(session.deviceCode == "device")
        #expect(session.userCode == "USER-CODE")
        #expect(session.interval == 5)
        let request = await client.requests.first
        #expect(request?.method == "POST")
        #expect(request?.url.absoluteString == "https://github.com/login/device/code")
        #expect(request?.bodyString.contains("client_id=client-id") == true)
        #expect(request?.bodyString.contains("scope=repo%20read%3Auser") == true)
    }

    @Test func oauthDeviceCompletionReturnsCredential() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"access","refresh_token":"refresh","token_type":"bearer","scope":"repo,read:user","expires_in":3600}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let credential = try await provider.completeOAuth(GitOAuthCompletionRequest(
            instance: .github,
            method: .oauthDevice,
            appConfig: OAuthAppConfig(clientID: "client-id"),
            deviceCode: "device"
        ))

        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.tokenType == "bearer")
        #expect(credential.scopes == ["repo", "read:user"])
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://github.com/login/oauth/access_token")
        #expect(request?.bodyString.contains("grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Adevice_code") == true)
        #expect(request?.bodyString.contains("device_code=device") == true)
    }

    @Test func oauthRefreshUsesRefreshGrantWhenCredentialHasRefreshToken() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"new-access","token_type":"bearer","scope":"repo"}"#.utf8)
            )
        ])
        let provider = GitHubProvider(
            httpClient: client,
            oauth: OAuthAppConfig(clientID: "client-id", clientSecret: "secret", scopes: ["repo"])
        )

        let refreshed = try await provider.refreshCredential(
            GitCredential(accessToken: "old", refreshToken: "refresh", scopes: ["repo"]),
            instance: .github
        )

        #expect(refreshed.accessToken == "new-access")
        let request = await client.requests.first
        #expect(request?.bodyString.contains("grant_type=refresh_token") == true)
        #expect(request?.bodyString.contains("refresh_token=refresh") == true)
        #expect(request?.bodyString.contains("client_secret=secret") == true)
    }

    @Test func repositoriesFollowGitHubPagination() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                headers: ["Link": #"<https://api.github.com/user/repos?page=2>; rel="next""#],
                body: Data(#"[{"name":"repo-one","full_name":"owner/repo-one","private":false,"fork":false,"default_branch":"main","html_url":"https://github.com/owner/repo-one","clone_url":"https://github.com/owner/repo-one.git","permissions":{"pull":true,"push":true,"admin":false}}]"#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"name":"repo-two","full_name":"owner/repo-two","private":true,"fork":false,"default_branch":"main","permissions":{"pull":true,"push":false,"admin":false}}]"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)
        let context = GitProviderRequestContext(
            connection: GitConnection(
                id: "connection",
                instance: .github,
                accountID: "1",
                accountLogin: "octocat",
                authMethod: .personalAccessToken,
                createdAt: Date(),
                updatedAt: Date()
            ),
            credential: GitCredential(accessToken: "secret-token")
        )

        let repositories = try await provider.repositories(context: context)

        #expect(repositories.items.map(\.reference.name) == ["repo-one", "repo-two"])
        #expect(repositories.items.first?.permissions.canPush == true)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString.contains("per_page=100"))
        #expect(requests[1].url.absoluteString == "https://api.github.com/user/repos?page=2")
    }

    @Test func branchesDecodeCommitSHA() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"name":"main","commit":{"sha":"abc123"},"protected":true}]"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)
        let repository = GitRepositoryReference(instance: .github, namespace: "owner", name: "repo")

        let branches = try await provider.branches(
            repository: repository,
            context: GitProviderRequestContext(connection: nil, credential: nil)
        )

        #expect(branches.items == [GitBranch(name: "main", commitSHA: "abc123", isProtected: true)])
    }

    @Test func readFileDecodesBase64Content() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: try fixtureData("GitHub/read-file.json")
            )
        ])
        let provider = GitHubProvider(httpClient: client)
        let file = try await provider.readFile(fileReference(path: "docs/hello.txt"), context: unauthenticatedContext)

        #expect(String(decoding: file.content, as: UTF8.self) == "hello")
        #expect(file.version == .blobSHA("blob-sha"))
        let request = await client.requests.first
        #expect(request?.method == "GET")
        #expect(request?.url.absoluteString == "https://api.github.com/repos/owner/repo/contents/docs/hello.txt?ref=main")
    }

    @Test func readFileOverSizeLimitThrowsFileTooLarge() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"type":"file","encoding":"base64","size":100000001,"name":"large.bin","path":"large.bin","content":"","sha":"blob-sha"}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        await #expect(throws: GitPontError.self) {
            _ = try await provider.readFile(fileReference(path: "large.bin"), context: unauthenticatedContext)
        }
    }

    @Test func listDirectoryMapsEntryTypes() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: try fixtureData("GitHub/list-directory.json")
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let list = try await provider.listDirectory(fileReference(path: "docs"), context: unauthenticatedContext)

        #expect(list.items.map(\.type) == [.file, .directory])
        #expect(list.items.map(\.path) == ["docs/a.md", "docs/nested"])
    }

    @Test func commitFileSendsShaWhenExpectedVersionExists() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"content":{"type":"file","name":"hello.txt","path":"hello.txt","sha":"new-blob"},"commit":{"sha":"commit-sha","html_url":"https://github.com/owner/repo/commit/commit-sha"}}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let result = try await provider.commitFile(
            GitFileChange(
                reference: fileReference(path: "hello.txt"),
                content: Data("hello".utf8),
                message: "Update hello",
                targetBranch: "main",
                expectedVersion: .blobSHA("old-blob")
            ),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "commit-sha")
        #expect(result.newVersion == .blobSHA("new-blob"))
        let request = await client.requests.first
        #expect(request?.method == "PUT")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""sha":"old-blob""#))
        #expect(body.contains(#""content":"aGVsbG8=""#))
        #expect(body.contains(#""branch":"main""#))
    }

    @Test func commitFileConflictIncludesReference() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 409, body: Data(#"{"message":"Conflict"}"#.utf8))
        ])
        let provider = GitHubProvider(httpClient: client)
        let reference = fileReference(path: "hello.txt")

        do {
            _ = try await provider.commitFile(
                GitFileChange(
                    reference: reference,
                    content: Data("hello".utf8),
                    message: "Update hello",
                    targetBranch: "main",
                    expectedVersion: .blobSHA("old-blob")
                ),
                context: authenticatedContext
            )
            Issue.record("Expected conflict")
        } catch let error as GitPontError {
            guard case .conflict(let conflict) = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
            #expect(conflict.reference == reference)
            #expect(conflict.expectedVersion == .blobSHA("old-blob"))
        }
    }

    @Test func emptyContentCommitIsStillAWriteRequest() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"content":{"type":"file","name":"empty.txt","path":"empty.txt","sha":"new-blob"},"commit":{"sha":"commit-sha"}}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        _ = try await provider.commitFile(
            GitFileChange(
                reference: fileReference(path: "empty.txt"),
                content: Data(),
                message: "Empty file",
                targetBranch: "main",
                expectedVersion: .blobSHA("old-blob")
            ),
            context: authenticatedContext
        )

        let request = await client.requests.first
        #expect(request?.method == "PUT")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""content":"""#))
    }

    @Test func deleteFileRequiresBlobSHA() async throws {
        let provider = GitHubProvider(httpClient: MockHTTPClient())

        await #expect(throws: GitPontError.self) {
            try await provider.deleteFile(
                GitFileDeleteRequest(
                    reference: fileReference(path: "hello.txt"),
                    message: "Delete hello",
                    targetBranch: "main",
                    expectedVersion: .commitID("not-a-blob")
                ),
                context: authenticatedContext
            )
        }
    }

    @Test func deleteFileSendsDeletePayload() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"commit":{"sha":"delete-commit","html_url":"https://github.com/owner/repo/commit/delete-commit"}}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let result = try await provider.deleteFile(
            GitFileDeleteRequest(
                reference: fileReference(path: "hello.txt"),
                message: "Delete hello",
                targetBranch: "main",
                expectedVersion: .blobSHA("old-blob")
            ),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "delete-commit")
        #expect(result.newVersion == nil)
        let request = await client.requests.first
        #expect(request?.method == "DELETE")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""sha":"old-blob""#))
    }

    @Test func deleteFileConflictIncludesReference() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 409, body: Data(#"{"message":"Conflict"}"#.utf8))
        ])
        let provider = GitHubProvider(httpClient: client)
        let reference = fileReference(path: "hello.txt")

        do {
            _ = try await provider.deleteFile(
                GitFileDeleteRequest(
                    reference: reference,
                    message: "Delete hello",
                    targetBranch: "main",
                    expectedVersion: .blobSHA("old-blob")
                ),
                context: authenticatedContext
            )
            Issue.record("Expected conflict")
        } catch let error as GitPontError {
            guard case .conflict(let conflict) = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
            #expect(conflict.reference == reference)
            #expect(conflict.expectedVersion == .blobSHA("old-blob"))
        }
    }

    @Test func createBranchLoadsBaseRefAndPostsNewRef() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"ref":"refs/heads/main","object":{"sha":"base-sha"}}"#.utf8)),
            HTTPResponse(statusCode: 201, body: Data(#"{"ref":"refs/heads/feature","object":{"sha":"base-sha"}}"#.utf8))
        ])
        let provider = GitHubProvider(httpClient: client)

        let branch = try await provider.createBranch(
            GitCreateBranchRequest(repository: repositoryReference, name: "feature", fromRef: "main"),
            context: authenticatedContext
        )

        #expect(branch == GitBranch(name: "feature", commitSHA: "base-sha"))
        let requests = await client.requests
        #expect(requests.map(\.method) == ["GET", "POST"])
        #expect(requests[1].url.absoluteString == "https://api.github.com/repos/owner/repo/git/refs")
        #expect(String(decoding: requests[1].body ?? Data(), as: UTF8.self).contains(#""ref":"refs\/heads\/feature""#))
    }

    @Test func deleteBranchDeletesHeadRef() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 204)
        ])
        let provider = GitHubProvider(httpClient: client)

        try await provider.deleteBranch(
            GitDeleteBranchRequest(repository: repositoryReference, name: "feature/live-write"),
            context: authenticatedContext
        )

        let request = await client.requests.first
        #expect(request?.method == "DELETE")
        #expect(request?.url.absoluteString == "https://api.github.com/repos/owner/repo/git/ref/heads/feature/live-write")
    }

    @Test func createPullRequestUsesForkHead() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 201,
                body: Data(#"{"id":99,"number":7,"title":"Update","html_url":"https://github.com/owner/repo/pull/7","head":{"ref":"feature"},"base":{"ref":"main"}}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)
        let fork = GitRepositoryReference(instance: .github, namespace: "octocat", name: "repo")

        let pullRequest = try await provider.createPullRequest(
            GitPullRequestRequest(
                repository: repositoryReference,
                title: "Update",
                body: "Body",
                sourceBranch: "feature",
                sourceRepository: fork,
                targetBranch: "main",
                draft: true
            ),
            context: authenticatedContext
        )

        #expect(pullRequest.number == 7)
        let body = String(decoding: await client.requests.first?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""head":"octocat:feature""#))
        #expect(body.contains(#""draft":true"#))
    }

    @Test func createRepositoryUsesPersonalEndpointByDefault() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 201,
                body: Data(#"{"name":"new-repo","full_name":"octocat/new-repo","private":true,"fork":false,"default_branch":"main","permissions":{"pull":true,"push":true,"admin":true}}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let repository = try await provider.createRepository(
            GitCreateRepositoryRequest(
                name: "new-repo",
                description: "Test repo",
                isPrivate: true,
                initializeWithReadme: true
            ),
            context: authenticatedContext
        )

        #expect(repository.reference.namespace == "octocat")
        let request = await client.requests.first
        #expect(request?.method == "POST")
        #expect(request?.url.absoluteString == "https://api.github.com/user/repos")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""auto_init":true"#))
        #expect(body.contains(#""private":true"#))
    }

    @Test func facadeCommitFileResolvesCredentialContext() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"content":{"type":"file","name":"hello.txt","path":"hello.txt","sha":"new-blob"},"commit":{"sha":"commit-sha"}}"#.utf8)
            )
        ])
        let connectionStore = InMemoryConnectionStore()
        let credentialStore = InMemoryCredentialStore()
        let connection = GitConnection(
            id: "github-connection",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .personalAccessToken,
            createdAt: Date(),
            updatedAt: Date()
        )
        await connectionStore.save(connection)
        await credentialStore.save(GitCredential(accessToken: "secret-token"), for: connection.id)
        let gitPont = GitPont(
            providers: [GitHubProvider(httpClient: client)],
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            httpClient: client
        )

        let result = try await gitPont.commitFile(
            fileReference(path: "hello.txt"),
            content: Data("hello".utf8),
            message: "Update hello",
            expectedVersion: .blobSHA("old-blob")
        )

        #expect(result.commitSHA == "commit-sha")
        let request = await client.requests.first
        #expect(request?.headers["Authorization"] == "Bearer secret-token")
    }

    @Test func forkRepositoryPostsForkEndpoint() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data("[]".utf8)),
            HTTPResponse(
                statusCode: 202,
                body: Data(#"{"name":"repo","full_name":"octocat/repo","private":false,"fork":true,"default_branch":"main","parent":{"name":"repo","full_name":"owner/repo","default_branch":"main"}}"#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"name":"repo","full_name":"octocat/repo","private":false,"fork":true,"default_branch":"main","parent":{"name":"repo","full_name":"owner/repo","default_branch":"main"}}"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let fork = try await provider.forkRepository(repositoryReference, context: authenticatedContext)

        #expect(fork.isFork)
        #expect(fork.reference.namespace == "octocat")
        let requests = await client.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[0].url.absoluteString == "https://api.github.com/repos/owner/repo/forks?per_page=100")
        #expect(requests[1].url.absoluteString == "https://api.github.com/repos/owner/repo/forks")
        #expect(requests[2].url.absoluteString == "https://api.github.com/repos/octocat/repo")
    }

    @Test func forkRepositoryReusesExistingConnectedAccountFork() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"name":"repo","full_name":"octocat/repo","private":false,"fork":true,"default_branch":"main","parent":{"name":"repo","full_name":"owner/repo","default_branch":"main"}}]"#.utf8)
            )
        ])
        let provider = GitHubProvider(httpClient: client)

        let fork = try await provider.forkRepository(repositoryReference, context: authenticatedContext)

        #expect(fork.isFork)
        #expect(fork.reference.namespace == "octocat")
        #expect(await client.requests.count == 1)
    }
}

private struct MockHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200)
    }
}

private let repositoryReference = GitRepositoryReference(instance: .github, namespace: "owner", name: "repo")

private func fileReference(path: String) -> GitFileReference {
    GitFileReference(repository: repositoryReference, path: path, ref: "main")
}

private let unauthenticatedContext = GitProviderRequestContext(connection: nil, credential: nil)

private let authenticatedContext = GitProviderRequestContext(
    connection: GitConnection(
        id: "connection",
        instance: .github,
        accountID: "1",
        accountLogin: "octocat",
        authMethod: .personalAccessToken,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    ),
    credential: GitCredential(accessToken: "secret-token")
)

private actor RecordingHTTPClient: HTTPClient {
    private var responses: [HTTPResponse]
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard !responses.isEmpty else {
            return HTTPResponse(statusCode: 500)
        }
        return responses.removeFirst()
    }
}

private extension HTTPRequest {
    var bodyString: String {
        body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

private func fixtureData(_ path: String) throws -> Data {
    let fileURL = URL(fileURLWithPath: path)
    let url = Bundle.module.url(
        forResource: fileURL.deletingPathExtension().lastPathComponent,
        withExtension: fileURL.pathExtension
    )!
    return try Data(contentsOf: url)
}
