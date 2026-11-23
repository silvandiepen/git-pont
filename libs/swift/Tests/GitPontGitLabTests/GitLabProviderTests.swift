import Foundation
import Testing
import GitPontCore
@testable import GitPontGitLab

@Suite("GitLabProvider")
struct GitLabProviderTests {
    @Test func customHostsRequireConfiguredInstance() {
        let provider = GitLabProvider(httpClient: MockHTTPClient(), instances: [.gitLabCloud])
        #expect(!provider.canHandle(url: URL(string: "https://gitlab.company.com/group/project")!))
    }

    @Test func parsesSubgroupRepositoryURL() throws {
        let provider = GitLabProvider(httpClient: MockHTTPClient())
        let result = try provider.parse(url: URL(string: "https://gitlab.com/group/subgroup/project")!)

        guard case .resolved(let reference) = result else {
            Issue.record("Expected resolved reference")
            return
        }

        #expect(reference.namespace == "group/subgroup")
        #expect(reference.name == "project")
    }

    @Test func accountLoadsCurrentUser() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"id":42,"username":"dev","name":"Dev User","avatar_url":"https://example.com/avatar.png","email":"dev@example.com"}"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let account = try await provider.account(
            instance: .gitLabCloud,
            credential: GitCredential(accessToken: "secret-token")
        )

        #expect(account.id == "42")
        #expect(account.login == "dev")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://gitlab.com/api/v4/user")
        #expect(request?.headers["PRIVATE-TOKEN"] == "secret-token")
    }

    @Test func oauthPKCEStartReturnsBrowserSession() async throws {
        let provider = GitLabProvider(httpClient: MockHTTPClient())

        let result = try await provider.startOAuth(GitOAuthStartRequest(
            instance: .gitLabCloud,
            method: .oauthPKCE,
            appConfig: OAuthAppConfig(
                clientID: "client-id",
                redirectURI: URL(string: "gitpont://oauth/gitlab")!,
                scopes: ["read_user", "api"]
            )
        ))

        guard case .browser(let session) = result else {
            Issue.record("Expected browser session")
            return
        }
        #expect(session.authorizationURL.absoluteString.hasPrefix("https://gitlab.com/oauth/authorize?"))
        #expect(session.authorizationURL.absoluteString.contains("client_id=client-id"))
        #expect(session.authorizationURL.absoluteString.contains("response_type=code"))
        #expect(session.authorizationURL.absoluteString.contains("code_challenge_method=S256"))
        #expect(session.authorizationURL.absoluteString.contains("scope=read_user%20api"))
        #expect(!session.state.isEmpty)
        #expect(session.codeVerifier?.count ?? 0 >= 43)
    }

    @Test func oauthPKCECompletionPostsTokenRequest() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"access","refresh_token":"refresh","token_type":"bearer","expires_in":7200,"created_at":1000,"scope":"api read_user"}"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let credential = try await provider.completeOAuth(GitOAuthCompletionRequest(
            instance: .gitLabCloud,
            method: .oauthPKCE,
            appConfig: OAuthAppConfig(
                clientID: "client-id",
                clientSecret: "secret",
                redirectURI: URL(string: "gitpont://oauth/gitlab")!
            ),
            callbackURL: URL(string: "gitpont://oauth/gitlab?code=returned&state=state")!,
            state: "state",
            codeVerifier: "verifier"
        ))

        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.expiresAt == Date(timeIntervalSince1970: 8200))
        #expect(credential.scopes == ["api", "read_user"])
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://gitlab.com/oauth/token")
        #expect(request?.bodyString.contains("grant_type=authorization_code") == true)
        #expect(request?.bodyString.contains("code=returned") == true)
        #expect(request?.bodyString.contains("code_verifier=verifier") == true)
    }

    @Test func oauthRefreshPostsRefreshGrant() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"bearer","expires_in":7200,"created_at":2000,"scope":"api"}"#.utf8)
            )
        ])
        let provider = GitLabProvider(
            httpClient: client,
            oauth: OAuthAppConfig(clientID: "client-id", redirectURI: URL(string: "gitpont://oauth/gitlab")!)
        )

        let credential = try await provider.refreshCredential(
            GitCredential(accessToken: "old", refreshToken: "refresh"),
            instance: .gitLabCloud
        )

        #expect(credential.accessToken == "new-access")
        #expect(credential.refreshToken == "new-refresh")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://gitlab.com/oauth/token")
        #expect(request?.bodyString.contains("grant_type=refresh_token") == true)
        #expect(request?.bodyString.contains("refresh_token=refresh") == true)
    }

    @Test func repositoriesFollowGitLabPagination() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                headers: ["x-next-page": "2"],
                body: Data(#"[{"id":1,"path":"project-one","path_with_namespace":"group/project-one","visibility":"private","default_branch":"main","web_url":"https://gitlab.com/group/project-one","http_url_to_repo":"https://gitlab.com/group/project-one.git","permissions":{"project_access":{"access_level":30}}}]"#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"id":2,"path":"project-two","path_with_namespace":"group/project-two","visibility":"public","default_branch":"main","permissions":{"project_access":{"access_level":10}}}]"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let repositories = try await provider.repositories(context: authenticatedContext)

        #expect(repositories.items.map(\.reference.name) == ["project-one", "project-two"])
        #expect(repositories.items.first?.permissions.canPush == true)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString.contains("membership=true"))
        #expect(requests[1].url.absoluteString.contains("page=2"))
    }

    @Test func branchesDecodeCommitID() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"name":"main","commit":{"id":"commit-sha"},"protected":true,"default":true}]"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let branches = try await provider.branches(repository: repositoryReference, context: unauthenticatedContext)

        #expect(branches.items == [GitBranch(name: "main", commitSHA: "commit-sha", isDefault: true, isProtected: true)])
        #expect(await client.requests.first?.url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/branches?per_page=100")
    }

    @Test func readFileDecodesBase64Content() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: try fixtureData("GitLab/read-file.json")
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let file = try await provider.readFile(fileReference(path: "docs/hello.txt"), context: unauthenticatedContext)

        #expect(String(decoding: file.content, as: UTF8.self) == "hello")
        #expect(file.version == .commitID("last-commit"))
        #expect(await client.requests.first?.url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/files/docs%2Fhello.txt?ref=main")
    }

    @Test func readFileOverSizeLimitThrowsFileTooLarge() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"file_path":"large.bin","content":"","last_commit_id":"last-commit","blob_id":"blob","size":100000001}"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        await #expect(throws: GitPontError.self) {
            _ = try await provider.readFile(fileReference(path: "large.bin"), context: unauthenticatedContext)
        }
    }

    @Test func listDirectoryMapsTreeEntries() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: try fixtureData("GitLab/list-directory.json")
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let list = try await provider.listDirectory(fileReference(path: "docs"), context: unauthenticatedContext)

        #expect(list.items.map(\.type) == [.file, .directory])
        #expect(await client.requests.first?.url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/tree?path=docs&ref=main&per_page=100")
    }

    @Test func commitFileUpdatesAndRefreshesVersion() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"commit_id":"new-commit"}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"file_path":"hello.txt","content":"aGVsbG8=","last_commit_id":"fresh-commit","size":5}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let result = try await provider.commitFile(
            GitFileChange(
                reference: fileReference(path: "hello.txt"),
                content: Data("hello".utf8),
                message: "Update hello",
                targetBranch: "main",
                expectedVersion: .commitID("old-commit")
            ),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "new-commit")
        #expect(result.newVersion == .commitID("fresh-commit"))
        let requests = await client.requests
        #expect(requests[0].method == "PUT")
        let body = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""last_commit_id":"old-commit""#))
        #expect(body.contains(#""encoding":"base64""#))
    }

    @Test func commitFileConflictIncludesReference() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 409, body: Data(#"{"message":"Conflict"}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)
        let reference = fileReference(path: "hello.txt")

        do {
            _ = try await provider.commitFile(
                GitFileChange(
                    reference: reference,
                    content: Data("hello".utf8),
                    message: "Update hello",
                    targetBranch: "main",
                    expectedVersion: .commitID("old-commit")
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
            #expect(conflict.expectedVersion == .commitID("old-commit"))
        }
    }

    @Test func emptyContentCommitIsStillAWriteRequest() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"commit_id":"new-commit"}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"file_path":"empty.txt","content":"","last_commit_id":"fresh-commit","size":0}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        _ = try await provider.commitFile(
            GitFileChange(
                reference: fileReference(path: "empty.txt"),
                content: Data(),
                message: "Empty file",
                targetBranch: "main",
                expectedVersion: .commitID("old-commit")
            ),
            context: authenticatedContext
        )

        let request = await client.requests.first
        #expect(request?.method == "PUT")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""content":"""#))
    }

    @Test func deleteFileRequiresCommitID() async throws {
        let provider = GitLabProvider(httpClient: MockHTTPClient())

        await #expect(throws: GitPontError.self) {
            try await provider.deleteFile(
                GitFileDeleteRequest(
                    reference: fileReference(path: "hello.txt"),
                    message: "Delete hello",
                    targetBranch: "main",
                    expectedVersion: .blobSHA("blob")
                ),
                context: authenticatedContext
            )
        }
    }

    @Test func deleteFileSendsDeletePayload() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"commit_id":"delete-commit"}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let result = try await provider.deleteFile(
            GitFileDeleteRequest(
                reference: fileReference(path: "hello.txt"),
                message: "Delete hello",
                targetBranch: "main",
                expectedVersion: .commitID("old-commit")
            ),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "delete-commit")
        let request = await client.requests.first
        #expect(request?.method == "DELETE")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""last_commit_id":"old-commit""#))
        #expect(body.contains(#""commit_message":"Delete hello""#))
    }

    @Test func deleteFileConflictIncludesReference() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 409, body: Data(#"{"message":"Conflict"}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)
        let reference = fileReference(path: "hello.txt")

        do {
            _ = try await provider.deleteFile(
                GitFileDeleteRequest(
                    reference: reference,
                    message: "Delete hello",
                    targetBranch: "main",
                    expectedVersion: .commitID("old-commit")
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
            #expect(conflict.expectedVersion == .commitID("old-commit"))
        }
    }

    @Test func createBranchPostsBranchQuery() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 201, body: Data(#"{"name":"feature","commit":{"id":"base-sha"},"protected":false}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let branch = try await provider.createBranch(
            GitCreateBranchRequest(repository: repositoryReference, name: "feature", fromRef: "main"),
            context: authenticatedContext
        )

        #expect(branch == GitBranch(name: "feature", commitSHA: "base-sha"))
        #expect(await client.requests.first?.url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/branches?branch=feature&ref=main")
    }

    @Test func deleteBranchDeletesRepositoryBranch() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 204)
        ])
        let provider = GitLabProvider(httpClient: client)

        try await provider.deleteBranch(
            GitDeleteBranchRequest(repository: repositoryReference, name: "feature/live-write"),
            context: authenticatedContext
        )

        let request = await client.requests.first
        #expect(request?.method == "DELETE")
        #expect(request?.url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/branches/feature%2Flive-write")
    }

    @Test func createMergeRequestPrefixesDraftTitle() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 201,
                body: Data(#"{"id":100,"iid":5,"title":"Draft: Update","web_url":"https://gitlab.com/group/project/-/merge_requests/5","source_branch":"feature","target_branch":"main"}"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let mergeRequest = try await provider.createPullRequest(
            GitPullRequestRequest(
                repository: repositoryReference,
                title: "Update",
                body: "Body",
                sourceBranch: "feature",
                targetBranch: "main",
                draft: true
            ),
            context: authenticatedContext
        )

        #expect(mergeRequest.number == 5)
        let body = String(decoding: await client.requests.first?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""title":"Draft: Update""#))
        #expect(body.contains(#""source_branch":"feature""#))
    }

    @Test func createRepositoryPostsProjectPayload() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 201,
                body: Data(#"{"id":3,"path":"new-project","path_with_namespace":"group/new-project","visibility":"private","default_branch":"main","permissions":{"project_access":{"access_level":40}}}"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let repository = try await provider.createRepository(
            GitCreateRepositoryRequest(
                name: "new-project",
                namespace: "10",
                description: "New project",
                isPrivate: true,
                initializeWithReadme: true
            ),
            context: authenticatedContext
        )

        #expect(repository.reference.name == "new-project")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://gitlab.com/api/v4/projects")
        let body = String(decoding: request?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""namespace_id":10"#))
        #expect(body.contains(#""initialize_with_readme":true"#))
    }

    @Test func forkRepositoryPostsForkEndpoint() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data("[]".utf8)),
            HTTPResponse(
                statusCode: 202,
                body: Data(#"{"id":4,"path":"project","path_with_namespace":"dev/project","visibility":"private","default_branch":"main","forked_from_project":{"id":1,"path":"project","path_with_namespace":"group/project"}}"#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"id":4,"path":"project","path_with_namespace":"dev/project","visibility":"private","default_branch":"main","forked_from_project":{"id":1,"path":"project","path_with_namespace":"group/project"}}"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let repository = try await provider.forkRepository(repositoryReference, context: authenticatedContext)

        #expect(repository.isFork)
        #expect(repository.parent?.namespace == "group")
        let requests = await client.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[0].url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/forks?per_page=100")
        #expect(requests[1].url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/fork")
        #expect(requests[2].url.absoluteString == "https://gitlab.com/api/v4/projects/dev%2Fproject")
    }

    @Test func forkRepositoryReusesExistingConnectedAccountFork() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"id":4,"path":"project","path_with_namespace":"dev/project","visibility":"private","default_branch":"main","forked_from_project":{"id":1,"path":"project","path_with_namespace":"group/project"}}]"#.utf8)
            )
        ])
        let provider = GitLabProvider(httpClient: client)

        let repository = try await provider.forkRepository(repositoryReference, context: authenticatedContext)

        #expect(repository.isFork)
        #expect(repository.reference.namespace == "dev")
        #expect(await client.requests.count == 1)
    }

    @Test func facadeCommitFileResolvesCredentialContext() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"commit_id":"new-commit"}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"file_path":"hello.txt","content":"aGVsbG8=","last_commit_id":"fresh-commit","size":5}"#.utf8))
        ])
        let connectionStore = InMemoryConnectionStore()
        let credentialStore = InMemoryCredentialStore()
        let connection = GitConnection(
            id: "gitlab-connection",
            instance: .gitLabCloud,
            accountID: "42",
            accountLogin: "dev",
            authMethod: .personalAccessToken,
            createdAt: Date(),
            updatedAt: Date()
        )
        await connectionStore.save(connection)
        await credentialStore.save(GitCredential(accessToken: "secret-token"), for: connection.id)
        let gitPont = GitPont(
            providers: [GitLabProvider(httpClient: client)],
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            httpClient: client
        )

        let result = try await gitPont.commitFile(
            fileReference(path: "hello.txt"),
            content: Data("hello".utf8),
            message: "Update hello",
            expectedVersion: .commitID("old-commit")
        )

        #expect(result.commitSHA == "new-commit")
        #expect(result.newVersion == .commitID("fresh-commit"))
        #expect(await client.requests.first?.headers["PRIVATE-TOKEN"] == "secret-token")
    }

    @Test func commitFilesSendsOneCommitWithAnActionPerFile() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"[{"name":"a.md","path":"docs/a.md","type":"blob"},{"name":"old.md","path":"docs/old.md","type":"blob"}]"#.utf8)),
            HTTPResponse(statusCode: 201, body: Data(#"{"id":"new-commit","web_url":"https://gitlab.com/group/project/-/commit/new-commit"}"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let result = try await provider.commitFiles(
            GitMultiFileCommit(repository: repositoryReference, branch: "main", message: "Change four files", operations: [
                .write("docs/a.md", Data("hello".utf8)),
                .write("docs/new.md", Data("hello".utf8)),
                .delete("docs/old.md"),
                .delete("docs/never-existed.md")
            ]),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "new-commit")
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/tree?path=docs&ref=main&per_page=100")
        #expect(requests[1].method == "POST")
        #expect(requests[1].url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/commits")
        let body = String(decoding: requests[1].body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""commit_message":"Change four files""#))
        #expect(body.contains(#"{"action":"update","content":"aGVsbG8=","encoding":"base64","file_path":"docs\/a.md"}"#))
        #expect(body.contains(#"{"action":"create","content":"aGVsbG8=","encoding":"base64","file_path":"docs\/new.md"}"#))
        #expect(body.contains(#"{"action":"delete","file_path":"docs\/old.md"}"#))
        #expect(!body.contains("never-existed"))
    }


    @Test func createWebhookPostsAPushHookWithTheSecretAsToken() async throws {
        let client = RecordingHTTPClient(responses: [HTTPResponse(statusCode: 201, body: Data(#"{"id":7}"#.utf8))])
        let provider = GitLabProvider(httpClient: client)

        let hook = try await provider.createWebhook(
            GitWebhookRequest(repository: repositoryReference, url: URL(string: "https://relay.example/hook/abc")!, secret: "s3cret", name: "Live updates"),
            context: authenticatedContext
        )

        #expect(hook.id == "7")
        let requests = await client.requests
        #expect(requests[0].method == "POST")
        #expect(requests[0].url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/hooks")
        #expect(requests[0].headers["Content-Type"] == "application/json")
        let body = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""push_events":true"#))
        #expect(body.contains(#""token":"s3cret""#))
        #expect(body.contains(#""name":"Live updates""#))
    }

    @Test func deleteWebhookDeletesItByID() async throws {
        let client = RecordingHTTPClient(responses: [HTTPResponse(statusCode: 204)])
        let provider = GitLabProvider(httpClient: client)

        try await provider.deleteWebhook(id: "7", repository: repositoryReference, context: authenticatedContext)

        let requests = await client.requests
        #expect(requests[0].method == "DELETE")
        #expect(requests[0].url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/hooks/7")
    }


    @Test func listTreeAsksForTheRecursiveTree() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"[{"name":"systems","path":"docs/systems","type":"tree"},{"name":"camera.md","path":"docs/systems/camera.md","type":"blob"}]"#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let tree = try await provider.listTree(GitFileReference(repository: repositoryReference, path: "docs", ref: "main"), context: authenticatedContext)

        #expect(tree.items.map(\.path) == ["docs/systems", "docs/systems/camera.md"])
        #expect(tree.items.map(\.type) == [.directory, .file])
        #expect(await client.requests.first?.url.absoluteString == "https://gitlab.com/api/v4/projects/group%2Fproject/repository/tree?path=docs&ref=main&recursive=true&per_page=100")
    }


    @Test func webURLPointsAtTheFilePage() {
        let provider = GitLabProvider(httpClient: RecordingHTTPClient(responses: []))
        let url = provider.webURL(for: GitFileReference(repository: repositoryReference, path: "docs/plan.md", ref: "main"))
        #expect(url?.absoluteString == "https://gitlab.com/group/project/-/blob/main/docs/plan.md")
    }

}

private struct MockHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200)
    }
}

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

private let repositoryReference = GitRepositoryReference(instance: .gitLabCloud, namespace: "group", name: "project")

private func fileReference(path: String) -> GitFileReference {
    GitFileReference(repository: repositoryReference, path: path, ref: "main")
}

private let unauthenticatedContext = GitProviderRequestContext(connection: nil, credential: nil)

private let authenticatedContext = GitProviderRequestContext(
    connection: GitConnection(
        id: "connection",
        instance: .gitLabCloud,
        accountID: "42",
        accountLogin: "dev",
        authMethod: .personalAccessToken,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    ),
    credential: GitCredential(accessToken: "secret-token")
)

private func encodedPath(_ url: URL?) -> String? {
    url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.percentEncodedPath }
}

private func querySet(_ url: URL?) -> Set<String> {
    Set(url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false)?.queryItems }?.map { "\($0.name)=\($0.value ?? "")" } ?? [])
}

@Suite("GitLabProvider history")
struct GitLabProviderHistoryTests {
    @Test func commitsListsNewestFirstWithPaging() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                headers: ["X-Next-Page": "3"],
                body: Data(#"""
                [{"id":"abc1234def","short_id":"abc1234","title":"Fix the parser","message":"Fix the parser\n\nIt dropped the last line.",
                  "author_name":"Mona","author_email":"mona@example.com","authored_date":"2026-11-20T09:45:00.000+01:00",
                  "parent_ids":["p1","p2"],"web_url":"https://gitlab.com/group/project/-/commit/abc1234def"}]
                """#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let list = try await provider.commits(
            GitCommitHistoryQuery(repository: repositoryReference, ref: "main", path: "src/a.swift", page: 2, perPage: 20),
            context: authenticatedContext)

        let commit = try #require(list.items.first)
        #expect(commit.sha == "abc1234def")
        #expect(commit.subject == "Fix the parser")
        #expect(commit.body == "It dropped the last line.")
        #expect(commit.authorName == "Mona")
        #expect(commit.authorEmail == "mona@example.com")
        #expect(commit.isMerge)
        #expect(commit.authoredAt == ISO8601DateFormatter().date(from: "2026-11-20T08:45:00Z"))
        #expect(commit.webURL?.absoluteString == "https://gitlab.com/group/project/-/commit/abc1234def")
        #expect(list.truncated)
        let url = await client.requests.first?.url
        #expect(url?.host == "gitlab.com")
        #expect(encodedPath(url) == "/api/v4/projects/group%2Fproject/repository/commits")
        #expect(querySet(url) == ["ref_name=main", "path=src/a.swift", "page=2", "per_page=20"])
    }

    @Test func commitsOnTheLastPageAreNotTruncated() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: ["X-Next-Page": ""], body: Data("[]".utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let list = try await provider.commits(GitCommitHistoryQuery(repository: repositoryReference), context: authenticatedContext)

        #expect(list.items.isEmpty)
        #expect(list.truncated == false)
        #expect(querySet(await client.requests.first?.url) == ["page=1", "per_page=30"])
    }

    @Test func commitReadsFilesWithTheirPatches() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"""
            {"id":"abc","title":"Rename","message":"Rename","author_name":"Mona","authored_date":"2026-11-20T08:45:00Z","parent_ids":["p"]}
            """#.utf8)),
            HTTPResponse(statusCode: 200, headers: ["X-Next-Page": "2"], body: Data(#"""
            [{"diff":"@@ -1 +1 @@\n-a\n+b","new_path":"b.txt","old_path":"a.txt","new_file":false,"renamed_file":true,"deleted_file":false},
             {"diff":"@@ -0,0 +1,2 @@\n+one\n+two\n","new_path":"new.txt","old_path":"new.txt","new_file":true,"renamed_file":false,"deleted_file":false},
             {"diff":"@@ -1 +0,0 @@\n-gone\n","new_path":"old.txt","old_path":"old.txt","new_file":false,"renamed_file":false,"deleted_file":true},
             {"diff":"Binary files /dev/null and b/logo.png differ\n","new_path":"logo.png","old_path":"logo.png","new_file":true,"renamed_file":false,"deleted_file":false}]
            """#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let detail = try await provider.commit(sha: "abc", repository: repositoryReference, context: authenticatedContext)

        #expect(detail.summary.sha == "abc")
        #expect(detail.summary.parentSHAs == ["p"])
        #expect(detail.files.count == 4)
        #expect(detail.files[0].status == .renamed)
        #expect(detail.files[0].path == "b.txt")
        #expect(detail.files[0].previousPath == "a.txt")
        #expect(detail.files[0].patch == "@@ -1 +1 @@\n-a\n+b\n")
        #expect(detail.files[0].additions == 1)
        #expect(detail.files[0].deletions == 1)
        #expect(detail.files[1].status == .added)
        #expect(detail.files[1].previousPath == nil)
        #expect(detail.files[1].additions == 2)
        #expect(detail.files[2].status == .removed)
        #expect(detail.files[2].deletions == 1)
        #expect(detail.files[3].isBinary)
        #expect(detail.files[3].patch == nil)
        #expect(detail.filesTruncated)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(encodedPath(requests.first?.url) == "/api/v4/projects/group%2Fproject/repository/commits/abc")
        #expect(encodedPath(requests.last?.url) == "/api/v4/projects/group%2Fproject/repository/commits/abc/diff")
        #expect(querySet(requests.last?.url) == ["per_page=100"])
    }

    @Test func commitUsesTheSelfHostedAPIBase() async throws {
        let instance = GitProviderInstance.gitLabSelfHosted(baseURL: URL(string: "https://git.example.com")!)
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"id":"abc","message":"Init","author_name":"Mona","parent_ids":[]}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data("[]".utf8))
        ])
        let provider = GitLabProvider(httpClient: client, instances: [instance])

        let detail = try await provider.commit(
            sha: "abc",
            repository: GitRepositoryReference(instance: instance, namespace: "team/sub", name: "app"),
            context: authenticatedContext)

        #expect(detail.files.isEmpty)
        #expect(detail.filesTruncated == false)
        let url = await client.requests.first?.url
        #expect(url?.host == "git.example.com")
        #expect(encodedPath(url) == "/api/v4/projects/team%2Fsub%2Fapp/repository/commits/abc")
    }

    @Test func mergeRequestsCarryStateAuthorAndDraft() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: ["X-Next-Page": "2"], body: Data(#"""
            [{"id":101,"iid":7,"title":"Add dark mode","description":"Follows the system.","state":"merged","draft":false,
              "created_at":"2026-11-19T10:00:00.000Z","updated_at":"2026-11-21T10:00:00.000Z",
              "web_url":"https://gitlab.com/group/project/-/merge_requests/7","author":{"username":"alex"},
              "source_branch":"dark","target_branch":"main"},
             {"id":102,"iid":8,"title":"WIP","description":null,"state":"opened","work_in_progress":true,
              "web_url":"https://gitlab.com/group/project/-/merge_requests/8","source_branch":"wip","target_branch":"main"},
             {"id":103,"iid":9,"title":"Dropped","state":"closed","draft":false,
              "web_url":"https://gitlab.com/group/project/-/merge_requests/9","source_branch":"old","target_branch":"main"}]
            """#.utf8))
        ])
        let provider = GitLabProvider(httpClient: client)

        let list = try await provider.pullRequests(
            GitPullRequestListQuery(repository: repositoryReference, filter: .all, page: 1, perPage: 3),
            context: authenticatedContext)

        #expect(list.items.map(\.state) == [.merged, .open, .closed])
        #expect(list.items[0].id == "101")
        #expect(list.items[0].number == 7)
        #expect(list.items[0].authorName == "alex")
        #expect(list.items[0].body == "Follows the system.")
        #expect(list.items[0].sourceBranch == "dark")
        #expect(list.items[0].targetBranch == "main")
        #expect(list.items[0].providerName == "GitLab")
        #expect(list.items[0].createdAt == ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z"))
        #expect(list.items[0].updatedAt == ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z"))
        #expect(list.items[0].isDraft == false)
        #expect(list.items[1].isDraft)
        #expect(list.items[1].body == nil)
        #expect(list.truncated)
        let url = await client.requests.first?.url
        #expect(encodedPath(url) == "/api/v4/projects/group%2Fproject/merge_requests")
        #expect(querySet(url) == ["state=all", "order_by=updated_at", "sort=desc", "per_page=3", "page=1"])
    }

    @Test func openMergeRequestFilterAsksForOpened() async throws {
        let client = RecordingHTTPClient(responses: [HTTPResponse(statusCode: 200, body: Data("[]".utf8))])
        let provider = GitLabProvider(httpClient: client)

        let list = try await provider.pullRequests(GitPullRequestListQuery(repository: repositoryReference), context: authenticatedContext)

        #expect(list.truncated == false)
        #expect(querySet(await client.requests.first?.url).contains("state=opened"))
    }
}
