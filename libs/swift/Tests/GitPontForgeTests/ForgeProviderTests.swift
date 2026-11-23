import Foundation
import Testing
import GitPontCore
@testable import GitPontForge

@Suite("ForgeProvider")
struct ForgeProviderTests {
    @Test func parsesCodebergRepositoryURL() throws {
        let provider = ForgeProvider(httpClient: MockHTTPClient())
        let result = try provider.parse(url: URL(string: "https://codeberg.org/owner/repo.git")!)

        guard case .resolved(let reference) = result else {
            Issue.record("Expected resolved reference")
            return
        }

        #expect(reference.instance == .codeberg)
        #expect(reference.namespace == "owner")
        #expect(reference.name == "repo")
    }

    @Test func accountLoadsCurrentUser() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"id":7,"login":"dev","full_name":"Dev User","avatar_url":"https://example.com/avatar.png","email":"dev@example.com"}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let account = try await provider.account(instance: .codeberg, credential: GitCredential(accessToken: "secret-token"))

        #expect(account.id == "7")
        #expect(account.login == "dev")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://codeberg.org/api/v1/user")
        #expect(request?.headers["Authorization"] == "token secret-token")
    }

    @Test func oauthStartReturnsBrowserSession() async throws {
        let provider = ForgeProvider(httpClient: MockHTTPClient())

        let result = try await provider.startOAuth(GitOAuthStartRequest(
            instance: .codeberg,
            method: .oauthPKCE,
            appConfig: OAuthAppConfig(
                clientID: "client-id",
                redirectURI: URL(string: "gitpont://oauth/forge")!,
                scopes: ["read:repository"]
            )
        ))

        guard case .browser(let session) = result else {
            Issue.record("Expected browser session")
            return
        }
        #expect(session.authorizationURL.absoluteString.hasPrefix("https://codeberg.org/login/oauth/authorize?"))
        #expect(session.authorizationURL.absoluteString.contains("client_id=client-id"))
        #expect(session.authorizationURL.absoluteString.contains("response_type=code"))
        #expect(session.authorizationURL.absoluteString.contains("code_challenge_method=S256"))
        #expect(!session.state.isEmpty)
        #expect(session.codeVerifier?.count ?? 0 >= 43)
    }

    @Test func oauthCompletionPostsAccessTokenRequest() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"access","refresh_token":"refresh","token_type":"bearer","expires_in":3600,"scope":"read:repository"}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let credential = try await provider.completeOAuth(GitOAuthCompletionRequest(
            instance: .codeberg,
            method: .oauthPKCE,
            appConfig: OAuthAppConfig(
                clientID: "client-id",
                clientSecret: "secret",
                redirectURI: URL(string: "gitpont://oauth/forge")!
            ),
            callbackURL: URL(string: "gitpont://oauth/forge?code=returned&state=state")!,
            state: "state",
            codeVerifier: "verifier"
        ))

        #expect(credential.accessToken == "access")
        #expect(credential.refreshToken == "refresh")
        #expect(credential.scopes == ["read:repository"])
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://codeberg.org/login/oauth/access_token")
        #expect(request?.bodyString.contains("grant_type=authorization_code") == true)
        #expect(request?.bodyString.contains("code=returned") == true)
        #expect(request?.bodyString.contains("client_secret=secret") == true)
    }

    @Test func oauthRefreshPostsRefreshGrant() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"access_token":"new-access","refresh_token":"new-refresh","token_type":"bearer","scope":"read:repository"}"#.utf8)
            )
        ])
        let provider = ForgeProvider(
            httpClient: client,
            oauth: OAuthAppConfig(clientID: "client-id", clientSecret: "secret")
        )

        let credential = try await provider.refreshCredential(
            GitCredential(accessToken: "old", refreshToken: "refresh"),
            instance: .codeberg
        )

        #expect(credential.accessToken == "new-access")
        #expect(credential.refreshToken == "new-refresh")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://codeberg.org/login/oauth/access_token")
        #expect(request?.bodyString.contains("grant_type=refresh_token") == true)
        #expect(request?.bodyString.contains("refresh_token=refresh") == true)
    }

    @Test func repositoriesDecodePermissions() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"name":"repo","full_name":"owner/repo","private":false,"fork":false,"default_branch":"main","html_url":"https://codeberg.org/owner/repo","clone_url":"https://codeberg.org/owner/repo.git","permissions":{"pull":true,"push":true,"admin":false}}]"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let repositories = try await provider.repositories(context: authenticatedContext)

        #expect(repositories.items.first?.reference.namespace == "owner")
        #expect(repositories.items.first?.permissions.canPush == true)
        #expect(await client.requests.first?.url.absoluteString == "https://codeberg.org/api/v1/user/repos?limit=50&page=1")
    }

    @Test func branchesDecodeCommitID() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"[{"name":"main","commit":{"id":"commit-sha"},"protected":true}]"#.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)

        let branches = try await provider.branches(repository: repositoryReference, context: unauthenticatedContext)

        #expect(branches.items == [GitBranch(name: "main", commitSHA: "commit-sha", isProtected: true)])
    }

    @Test func readFileDecodesBase64Content() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: try fixtureData("Forgejo/read-file.json")
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let file = try await provider.readFile(fileReference(path: "docs/hello.txt"), context: unauthenticatedContext)

        #expect(String(decoding: file.content, as: UTF8.self) == "hello")
        #expect(file.version == .blobSHA("blob-sha"))
        #expect(await client.requests.first?.url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/contents/docs/hello.txt?ref=main")
    }

    @Test func readFileOverSizeLimitThrowsFileTooLarge() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"type":"file","name":"large.bin","path":"large.bin","content":"","sha":"blob-sha","size":100000001}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        await #expect(throws: GitPontError.self) {
            _ = try await provider.readFile(fileReference(path: "large.bin"), context: unauthenticatedContext)
        }
    }

    @Test func listDirectoryMapsEntryTypes() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: try fixtureData("Forgejo/list-directory.json")
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let list = try await provider.listDirectory(fileReference(path: "docs"), context: unauthenticatedContext)

        #expect(list.items.map(\.type) == [.file, .directory])
    }

    @Test func commitFileSendsShaForUpdates() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"content":{"type":"file","name":"hello.txt","path":"hello.txt","sha":"new-blob"},"commit":{"sha":"commit-sha","html_url":"https://codeberg.org/owner/repo/commit/commit-sha"}}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

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
    }

    @Test func commitFileConflictIncludesReference() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 409, body: Data(#"{"message":"Conflict"}"#.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)
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
        let provider = ForgeProvider(httpClient: client)

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
        let provider = ForgeProvider(httpClient: MockHTTPClient())

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
                body: Data(#"{"content":null,"commit":{"sha":"delete-commit","html_url":"https://codeberg.org/owner/repo/commit/delete-commit"}}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

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
        let provider = ForgeProvider(httpClient: client)
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

    @Test func createBranchPostsPayload() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 201, body: Data(#"{"name":"feature","commit":{"id":"base-sha"},"protected":false}"#.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)

        let branch = try await provider.createBranch(
            GitCreateBranchRequest(repository: repositoryReference, name: "feature", fromRef: "main"),
            context: authenticatedContext
        )

        #expect(branch == GitBranch(name: "feature", commitSHA: "base-sha"))
        let body = String(decoding: await client.requests.first?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""new_branch_name":"feature""#))
        #expect(body.contains(#""old_ref_name":"main""#))
    }

    @Test func deleteBranchDeletesRepositoryBranch() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 204)
        ])
        let provider = ForgeProvider(httpClient: client)

        try await provider.deleteBranch(
            GitDeleteBranchRequest(repository: repositoryReference, name: "feature/live-write"),
            context: authenticatedContext
        )

        let request = await client.requests.first
        #expect(request?.method == "DELETE")
        #expect(request?.url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/branches/feature%2Flive-write")
    }

    @Test func createRepositoryUsesUserEndpoint() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 201,
                body: Data(#"{"name":"new-repo","full_name":"dev/new-repo","private":true,"fork":false,"default_branch":"main","permissions":{"pull":true,"push":true,"admin":true}}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let repository = try await provider.createRepository(
            GitCreateRepositoryRequest(name: "new-repo", description: "New repo", isPrivate: true, initializeWithReadme: true),
            context: authenticatedContext
        )

        #expect(repository.reference.namespace == "dev")
        #expect(await client.requests.first?.url.absoluteString == "https://codeberg.org/api/v1/user/repos")
    }

    @Test func forkRepositoryPostsForkEndpoint() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data("[]".utf8)),
            HTTPResponse(
                statusCode: 202,
                body: Data(#"{"name":"repo","full_name":"dev/repo","private":false,"fork":true,"default_branch":"main","parent":{"name":"repo","full_name":"owner/repo","default_branch":"main"}}"#.utf8)
            ),
            HTTPResponse(
                statusCode: 200,
                body: Data(#"{"name":"repo","full_name":"dev/repo","private":false,"fork":true,"default_branch":"main","parent":{"name":"repo","full_name":"owner/repo","default_branch":"main"}}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let repository = try await provider.forkRepository(repositoryReference, context: authenticatedContext)

        #expect(repository.isFork)
        #expect(repository.parent?.namespace == "owner")
        let requests = await client.requests
        #expect(requests.map(\.method) == ["GET", "POST", "GET"])
        #expect(requests[0].url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/forks?limit=50&page=1")
        #expect(requests[1].url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/forks")
        #expect(requests[2].url.absoluteString == "https://codeberg.org/api/v1/repos/dev/repo")
    }

    @Test func forkRepositoryReusesExistingConnectedAccountFork() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                body: Data(#"[{"name":"repo","full_name":"dev/repo","private":false,"fork":true,"default_branch":"main","parent":{"name":"repo","full_name":"owner/repo","default_branch":"main"}}]"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)

        let repository = try await provider.forkRepository(repositoryReference, context: authenticatedContext)

        #expect(repository.isFork)
        #expect(repository.reference.namespace == "dev")
        #expect(await client.requests.count == 1)
    }

    @Test func createPullRequestUsesForkHead() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 201,
                body: Data(#"{"id":9,"number":3,"title":"Update","html_url":"https://codeberg.org/owner/repo/pulls/3","head":{"ref":"feature"},"base":{"ref":"main"}}"#.utf8)
            )
        ])
        let provider = ForgeProvider(httpClient: client)
        let fork = GitRepositoryReference(instance: .codeberg, namespace: "dev", name: "repo")

        let pullRequest = try await provider.createPullRequest(
            GitPullRequestRequest(
                repository: repositoryReference,
                title: "Update",
                body: "Body",
                sourceBranch: "feature",
                sourceRepository: fork,
                targetBranch: "main"
            ),
            context: authenticatedContext
        )

        #expect(pullRequest.number == 3)
        let body = String(decoding: await client.requests.first?.body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""head":"dev:feature""#))
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
            id: "forge-connection",
            instance: .codeberg,
            accountID: "7",
            accountLogin: "dev",
            authMethod: .personalAccessToken,
            createdAt: Date(),
            updatedAt: Date()
        )
        await connectionStore.save(connection)
        await credentialStore.save(GitCredential(accessToken: "secret-token"), for: connection.id)
        let gitPont = GitPont(
            providers: [ForgeProvider(httpClient: client)],
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
        #expect(await client.requests.first?.headers["Authorization"] == "token secret-token")
    }

    @Test func commitFilesSendsOneChangeFilesRequest() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"[{"type":"file","name":"a.md","path":"docs/a.md","sha":"blob-a"},{"type":"file","name":"old.md","path":"docs/old.md","sha":"blob-old"}]"#.utf8)),
            HTTPResponse(statusCode: 201, body: Data(#"{"commit":{"sha":"new-commit","html_url":"https://codeberg.org/owner/repo/commit/new-commit"},"files":[]}"#.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)

        let result = try await provider.commitFiles(
            GitMultiFileCommit(repository: repositoryReference, branch: "main", message: "Change three files", operations: [
                .write("docs/a.md", Data("hello".utf8)),
                .write("docs/new.md", Data("hello".utf8)),
                .delete("docs/old.md")
            ]),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "new-commit")
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/contents/docs?ref=main")
        #expect(requests[1].method == "POST")
        #expect(requests[1].url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/contents")
        let body = String(decoding: requests[1].body ?? Data(), as: UTF8.self)
        #expect(body.contains(#"{"content":"aGVsbG8=","operation":"update","path":"docs\/a.md","sha":"blob-a"}"#))
        #expect(body.contains(#"{"content":"aGVsbG8=","operation":"create","path":"docs\/new.md"}"#))
        #expect(body.contains(#"{"operation":"delete","path":"docs\/old.md","sha":"blob-old"}"#))
    }


    @Test func createWebhookPostsAPushHook() async throws {
        let client = RecordingHTTPClient(responses: [HTTPResponse(statusCode: 201, body: Data(#"{"id":9}"#.utf8))])
        let provider = ForgeProvider(httpClient: client)

        let hook = try await provider.createWebhook(
            GitWebhookRequest(repository: repositoryReference, url: URL(string: "https://relay.example/hook/abc")!, secret: "s3cret"),
            context: authenticatedContext
        )

        #expect(hook.id == "9")
        let requests = await client.requests
        #expect(requests[0].url.absoluteString == "https://codeberg.org/api/v1/repos/owner/repo/hooks")
        #expect(requests[0].headers["Content-Type"] == "application/json")
        let body = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""type":"gitea""#))
        #expect(body.contains(#""events":["push"]"#))
        #expect(body.contains(#""secret":"s3cret""#))
    }


    @Test func webURLPointsAtTheFilePage() {
        let provider = ForgeProvider(httpClient: RecordingHTTPClient(responses: []))
        let url = provider.webURL(for: GitFileReference(repository: repositoryReference, path: "docs/plan.md", ref: "main"))
        #expect(url?.absoluteString == "https://codeberg.org/owner/repo/src/branch/main/docs/plan.md")
    }

}

@Suite("ForgeProvider history")
struct ForgeProviderHistoryTests {
    @Test func commitsListsNewestFirstWithPaging() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                headers: ["X-HasMore": "true"],
                body: Data(#"""
                [{"sha":"abc1234def","html_url":"https://codeberg.org/owner/repo/commit/abc1234def",
                  "commit":{"message":"Fix the parser\n\nIt dropped the last line.","author":{"name":"Mona","email":"mona@example.com","date":"2026-11-20T09:45:00+01:00"}},
                  "parents":[{"sha":"p1"},{"sha":"p2"}]}]
                """#.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)

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
        #expect(commit.webURL?.absoluteString == "https://codeberg.org/owner/repo/commit/abc1234def")
        #expect(list.truncated)
        let url = try #require(await client.requests.first?.url)
        let query = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { "\($0.name)=\($0.value ?? "")" } ?? [])
        #expect(url.host == "codeberg.org")
        #expect(url.path == "/api/v1/repos/owner/repo/commits")
        #expect(query == ["sha=main", "path=src/a.swift", "page=2", "limit=20", "stat=false", "files=false"])
    }

    @Test func commitsReadTheLinkHeaderWithoutHasMore() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(
                statusCode: 200,
                headers: ["Link": #"<https://codeberg.org/api/v1/repos/owner/repo/commits?page=2>; rel="next""#],
                body: Data("[]".utf8)),
            HTTPResponse(statusCode: 200, headers: ["X-HasMore": "false"], body: Data("[]".utf8))
        ])
        let provider = ForgeProvider(httpClient: client)
        let query = GitCommitHistoryQuery(repository: repositoryReference)

        #expect(try await provider.commits(query, context: unauthenticatedContext).truncated)
        #expect(try await provider.commits(query, context: unauthenticatedContext).truncated == false)
        let url = try #require(await client.requests.first?.url)
        #expect(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains { $0.name == "sha" } == false)
    }

    @Test func commitReadsTheSummaryAndParsesTheDiff() async throws {
        let diff = """
        diff --git a/a.txt b/b.txt
        similarity index 50%
        rename from a.txt
        rename to b.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..3333333
        Binary files /dev/null and b/logo.png differ

        """
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"""
            {"sha":"abc","html_url":"https://codeberg.org/owner/repo/commit/abc",
             "commit":{"message":"Rename","author":{"name":"Mona","email":"mona@example.com","date":"2026-11-20T08:45:00Z"}},
             "parents":[{"sha":"p"}]}
            """#.utf8)),
            HTTPResponse(statusCode: 200, headers: ["Content-Type": "text/plain"], body: Data(diff.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)

        let detail = try await provider.commit(sha: "abc", repository: repositoryReference, context: authenticatedContext)

        #expect(detail.summary.sha == "abc")
        #expect(detail.summary.message == "Rename")
        #expect(detail.summary.parentSHAs == ["p"])
        #expect(detail.files.count == 2)
        #expect(detail.files[0].status == .renamed)
        #expect(detail.files[0].path == "b.txt")
        #expect(detail.files[0].previousPath == "a.txt")
        #expect(detail.files[0].additions == 1)
        #expect(detail.files[0].deletions == 1)
        #expect(detail.files[0].patch == "@@ -1 +1 @@\n-a\n+b\n")
        #expect(detail.files[1].path == "logo.png")
        #expect(detail.files[1].status == .added)
        #expect(detail.files[1].isBinary)
        #expect(detail.files[1].patch == nil)
        #expect(detail.filesTruncated == false)
        let requests = await client.requests
        #expect(requests.map(\.url.path) == [
            "/api/v1/repos/owner/repo/git/commits/abc",
            "/api/v1/repos/owner/repo/git/commits/abc.diff"
        ])
        #expect(requests.last?.headers["Accept"] == "text/plain")
        #expect(requests.last?.headers["Authorization"] == "token secret-token")
    }

    @Test func pullRequestsCarryStateAuthorAndDraft() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, headers: ["X-HasMore": "false"], body: Data(#"""
            [{"id":1,"number":7,"title":"Add dark mode","body":"Follows the system.","state":"closed","merged":true,
              "merged_at":"2026-11-21T10:00:00Z","created_at":"2026-11-19T10:00:00Z","updated_at":"2026-11-21T10:00:00Z",
              "html_url":"https://codeberg.org/owner/repo/pulls/7","user":{"login":"alex"},"head":{"ref":"dark"},"base":{"ref":"main"}},
             {"id":2,"number":8,"title":"WIP: Sync","state":"open","merged":false,"html_url":"https://codeberg.org/owner/repo/pulls/8",
              "head":{"ref":"wip"},"base":{"ref":"main"}},
             {"id":3,"number":9,"title":"Tidy","state":"open","draft":true,"html_url":"https://codeberg.org/owner/repo/pulls/9",
              "head":{"ref":"tidy"},"base":{"ref":"main"}},
             {"id":4,"number":10,"title":"Drop it","state":"closed","merged":false,"draft":false,"html_url":"https://codeberg.org/owner/repo/pulls/10",
              "head":{"ref":"drop"},"base":{"ref":"main"}}]
            """#.utf8))
        ])
        let provider = ForgeProvider(httpClient: client)

        let list = try await provider.pullRequests(
            GitPullRequestListQuery(repository: repositoryReference, filter: .all, page: 3, perPage: 25),
            context: authenticatedContext)

        #expect(list.items.map(\.state) == [.merged, .open, .open, .closed])
        #expect(list.items.map(\.isDraft) == [false, true, true, false])
        #expect(list.items[0].id == "1")
        #expect(list.items[0].number == 7)
        #expect(list.items[0].authorName == "alex")
        #expect(list.items[0].body == "Follows the system.")
        #expect(list.items[0].sourceBranch == "dark")
        #expect(list.items[0].targetBranch == "main")
        #expect(list.items[0].providerName == "Forge")
        #expect(list.items[0].createdAt == ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z"))
        #expect(list.items[0].updatedAt == ISO8601DateFormatter().date(from: "2026-11-21T10:00:00Z"))
        #expect(list.truncated == false)
        let url = try #require(await client.requests.first?.url)
        let query = Set(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.map { "\($0.name)=\($0.value ?? "")" } ?? [])
        #expect(url.path == "/api/v1/repos/owner/repo/pulls")
        #expect(query == ["state=all", "sort=recentupdate", "limit=25", "page=3"])
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

private let repositoryReference = GitRepositoryReference(instance: .codeberg, namespace: "owner", name: "repo")

private func fileReference(path: String) -> GitFileReference {
    GitFileReference(repository: repositoryReference, path: path, ref: "main")
}

private let unauthenticatedContext = GitProviderRequestContext(connection: nil, credential: nil)

private let authenticatedContext = GitProviderRequestContext(
    connection: GitConnection(
        id: "connection",
        instance: .codeberg,
        accountID: "7",
        accountLogin: "dev",
        authMethod: .personalAccessToken,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    ),
    credential: GitCredential(accessToken: "secret-token")
)
