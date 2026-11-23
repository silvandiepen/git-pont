import Foundation
import Testing
import GitPontCore
@testable import GitPontBitbucket

@Suite("BitbucketProvider")
struct BitbucketProviderTests {
    @Test func parsesRepositoryURL() throws {
        let provider = BitbucketProvider(httpClient: MockHTTPClient())
        let result = try provider.parse(url: URL(string: "https://bitbucket.org/workspace/repo.git")!)

        guard case .resolved(let reference) = result else {
            Issue.record("Expected resolved reference")
            return
        }

        #expect(reference.instance == .bitbucketCloud)
        #expect(reference.namespace == "workspace")
        #expect(reference.name == "repo")
    }

    @Test func parsesSourceURL() throws {
        let provider = BitbucketProvider(httpClient: MockHTTPClient())
        let result = try provider.parse(url: URL(string: "https://bitbucket.org/workspace/repo/src/main/docs/hello.md")!)

        guard case .ambiguous(let candidates) = result else {
            Issue.record("Expected ambiguous slashed-branch candidates")
            return
        }

        #expect(candidates.contains { $0.ref == "main" && $0.path == "docs/hello.md" })
    }

    @Test func accountLoadsCurrentUser() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"uuid":"{user}","nickname":"dev","display_name":"Dev User","links":{"avatar":{"href":"https://example.com/avatar.png"}}}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let account = try await provider.account(instance: .bitbucketCloud, credential: GitCredential(accessToken: "secret-token"))

        #expect(account.id == "{user}")
        #expect(account.login == "dev")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://api.bitbucket.org/2.0/user")
        #expect(request?.headers["Authorization"] == "Bearer secret-token")
    }

    @Test func repositoriesDecodePage() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"values":[{"uuid":"{repo}","slug":"repo","name":"Repo","full_name":"workspace/repo","is_private":true,"mainbranch":{"name":"main"},"links":{"html":{"href":"https://bitbucket.org/workspace/repo"},"clone":[{"name":"https","href":"https://bitbucket.org/workspace/repo.git"}]}}]}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let repositories = try await provider.repositories(context: authenticatedContext)

        #expect(repositories.items.first?.reference.namespace == "workspace")
        #expect(repositories.items.first?.reference.name == "repo")
        #expect(await client.requests.first?.url.absoluteString == "https://api.bitbucket.org/2.0/repositories?role=member&pagelen=100")
    }

    @Test func branchesDecodeTargets() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"{"values":[{"name":"main","target":{"hash":"commit-sha"}}]}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let branches = try await provider.branches(repository: repositoryReference, context: unauthenticatedContext)

        #expect(branches.items == [GitBranch(name: "main", commitSHA: "commit-sha")])
        #expect(await client.requests.first?.url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/refs/branches?pagelen=100")
    }

    @Test func readFileLoadsRawContentAndVersion() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data("hello".utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"values":[{"commit":{"hash":"file-commit"}}]}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let file = try await provider.readFile(fileReference(path: "docs/hello.txt"), context: unauthenticatedContext)

        #expect(String(decoding: file.content, as: UTF8.self) == "hello")
        #expect(file.version == .commitID("file-commit"))
        let requests = await client.requests
        #expect(requests[0].url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/src/main/docs%2Fhello.txt")
        #expect(requests[1].url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/filehistory/main/docs%2Fhello.txt?pagelen=1")
    }

    @Test func commitFileUploadsMultipartForm() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 201, body: Data(#"{"hash":"new-commit","links":{"html":{"href":"https://bitbucket.org/workspace/repo/commits/new-commit"}}}"#.utf8)),
            HTTPResponse(statusCode: 200, body: Data("hello".utf8)),
            HTTPResponse(statusCode: 200, body: Data(#"{"values":[{"commit":{"hash":"new-commit"}}]}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let result = try await provider.commitFile(
            GitFileChange(
                reference: fileReference(path: "docs/hello.txt"),
                content: Data("hello".utf8),
                message: "Update file",
                targetBranch: "main",
                expectedVersion: .commitID("old-commit")
            ),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "new-commit")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/src")
        #expect(request?.headers["Content-Type"]?.contains("multipart/form-data") == true)
        #expect(request?.bodyString.contains("name=\"parents\"") == true)
        #expect(request?.bodyString.contains("old-commit") == true)
        #expect(request?.bodyString.contains("name=\"docs/hello.txt\"") == true)
    }

    @Test func createPullRequestPostsPayload() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 201, body: Data(#"{"id":7,"title":"Update","links":{"html":{"href":"https://bitbucket.org/workspace/repo/pull-requests/7"}},"source":{"branch":{"name":"feature"}},"destination":{"branch":{"name":"main"}}}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let pullRequest = try await provider.createPullRequest(
            GitPullRequestRequest(repository: repositoryReference, title: "Update", sourceBranch: "feature", targetBranch: "main"),
            context: authenticatedContext
        )

        #expect(pullRequest.number == 7)
        #expect(pullRequest.sourceBranch == "feature")
        let request = await client.requests.first
        #expect(request?.url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/pullrequests")
        #expect(request?.bodyString.contains("\"title\":\"Update\"") == true)
    }

    @Test func commitFilesPostsEveryFileInOneForm() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 201, body: Data(#"{"hash":"new-commit"}"#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let result = try await provider.commitFiles(
            GitMultiFileCommit(repository: repositoryReference, branch: "main", message: "Change three files", operations: [
                .write("docs/a.md", Data("hello".utf8)),
                .write("docs/new.md", Data("world".utf8)),
                .delete("docs/old.md")
            ]),
            context: authenticatedContext
        )

        #expect(result.commitSHA == "new-commit")
        let requests = await client.requests
        #expect(requests.count == 1)
        #expect(requests[0].method == "POST")
        #expect(requests[0].url.absoluteString.hasSuffix("/repositories/workspace/repo/src"))
        let body = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
        #expect(body.contains("name=\"message\"\r\n\r\nChange three files"))
        #expect(body.contains("name=\"docs/a.md\""))
        #expect(body.contains("name=\"docs/new.md\""))
        #expect(body.contains("name=\"files\"\r\n\r\ndocs/old.md"))
    }


    @Test func createWebhookPostsARepoPushHook() async throws {
        let client = RecordingHTTPClient(responses: [HTTPResponse(statusCode: 201, body: Data(#"{"uuid":"{abc-123}"}"#.utf8))])
        let provider = BitbucketProvider(httpClient: client)

        let hook = try await provider.createWebhook(
            GitWebhookRequest(repository: repositoryReference, url: URL(string: "https://relay.example/hook/abc")!, secret: "s3cret", name: "Live updates"),
            context: authenticatedContext
        )

        #expect(hook.id == "{abc-123}")
        let requests = await client.requests
        #expect(requests[0].url.absoluteString.hasSuffix("/repositories/workspace/repo/hooks"))
        let body = String(decoding: requests[0].body ?? Data(), as: UTF8.self)
        #expect(body.contains(#""events":["repo:push"]"#))
        #expect(body.contains(#""description":"Live updates""#))
    }


    @Test func webURLPointsAtTheFilePage() {
        let provider = BitbucketProvider(httpClient: RecordingHTTPClient(responses: []))
        let url = provider.webURL(for: GitFileReference(repository: repositoryReference, path: "docs/plan.md", ref: "main"))
        #expect(url?.absoluteString == "https://bitbucket.org/workspace/repo/src/main/docs/plan.md")
    }

}

private let repositoryReference = GitRepositoryReference(instance: .bitbucketCloud, namespace: "workspace", name: "repo")

private func fileReference(path: String) -> GitFileReference {
    GitFileReference(repository: repositoryReference, path: path, ref: "main")
}

private let authenticatedContext = GitProviderRequestContext(
    connection: GitConnection(
        id: "bitbucket-connection",
        instance: .bitbucketCloud,
        accountID: "{user}",
        accountLogin: "workspace",
        authMethod: .personalAccessToken,
        createdAt: Date(timeIntervalSince1970: 0),
        updatedAt: Date(timeIntervalSince1970: 0)
    ),
    credential: GitCredential(accessToken: "secret-token")
)

private let unauthenticatedContext = GitProviderRequestContext(connection: nil, credential: nil)

private struct MockHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw GitPontError.providerUnavailable("MockHTTPClient does not send requests")
    }
}

private actor RecordingHTTPClient: HTTPClient {
    private let responses: [HTTPResponse]
    private var index = 0
    private(set) var requests: [HTTPRequest] = []

    init(responses: [HTTPResponse]) {
        self.responses = responses
    }

    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        requests.append(request)
        guard index < responses.count else {
            throw GitPontError.providerUnavailable("No response queued")
        }
        let response = responses[index]
        index += 1
        return response
    }
}

private extension HTTPRequest {
    var bodyString: String {
        body.map { String(decoding: $0, as: UTF8.self) } ?? ""
    }
}

@Suite("BitbucketProvider history")
struct BitbucketProviderHistoryTests {
    @Test func commitsListARefWithPaging() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"""
            {"pagelen":20,"page":2,"next":"https://api.bitbucket.org/2.0/repositories/workspace/repo/commits/main?page=3",
             "values":[
               {"hash":"abc1234def","message":"Fix the parser\n\nIt dropped the last line.\n","date":"2026-11-20T08:45:00.123456+00:00",
                "author":{"raw":"Mona Lisa <mona@example.com>","user":{"display_name":"Mona"}},
                "parents":[{"hash":"p1"},{"hash":"p2"}],
                "links":{"html":{"href":"https://bitbucket.org/workspace/repo/commits/abc1234def"}}},
               {"hash":"def5678","message":"Unlinked author","date":"2026-11-19T08:45:00+02:00",
                "author":{"raw":"Ghost Writer <ghost@example.com>"},"parents":[{"hash":"abc1234def"}]}
             ]}
            """#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let list = try await provider.commits(
            GitCommitHistoryQuery(repository: repositoryReference, ref: "feature/x", path: "src/a.swift", page: 2, perPage: 20),
            context: authenticatedContext)

        #expect(list.items.count == 2)
        let commit = try #require(list.items.first)
        #expect(commit.sha == "abc1234def")
        #expect(commit.subject == "Fix the parser")
        #expect(commit.body == "It dropped the last line.")
        #expect(commit.authorName == "Mona")
        #expect(commit.authorEmail == "mona@example.com")
        #expect(commit.isMerge)
        #expect(commit.webURL?.absoluteString == "https://bitbucket.org/workspace/repo/commits/abc1234def")
        let expectedDate = try #require(ISO8601DateFormatter().date(from: "2026-11-20T08:45:00Z"))
        #expect(abs(try #require(commit.authoredAt).timeIntervalSince(expectedDate) - 0.123456) < 0.001)
        #expect(list.items[1].authorName == "Ghost Writer")
        #expect(list.items[1].authorEmail == "ghost@example.com")
        #expect(list.items[1].authoredAt == ISO8601DateFormatter().date(from: "2026-11-19T06:45:00Z"))
        #expect(list.truncated)
        let url = try #require(await client.requests.first?.url)
        let components = try #require(URLComponents(url: url, resolvingAgainstBaseURL: false))
        #expect(components.percentEncodedPath == "/2.0/repositories/workspace/repo/commits/feature%2Fx")
        let query = Set(components.queryItems?.map { "\($0.name)=\($0.value ?? "")" } ?? [])
        #expect(query == ["path=src/a.swift", "pagelen=20", "page=2"])
    }

    @Test func commitsWithoutARefUseTheDefaultBranchOrEveryBranch() async throws {
        let empty = Data(#"{"values":[]}"#.utf8)
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: empty),
            HTTPResponse(statusCode: 200, body: empty)
        ])
        let provider = BitbucketProvider(httpClient: client)
        let withDefault = GitRepositoryReference(instance: .bitbucketCloud, namespace: "workspace", name: "repo", defaultBranch: "trunk")

        let first = try await provider.commits(GitCommitHistoryQuery(repository: withDefault), context: authenticatedContext)
        _ = try await provider.commits(GitCommitHistoryQuery(repository: repositoryReference), context: authenticatedContext)

        #expect(first.truncated == false)
        let requests = await client.requests
        #expect(requests[0].url.path == "/2.0/repositories/workspace/repo/commits/trunk")
        #expect(requests[1].url.path == "/2.0/repositories/workspace/repo/commits")
    }

    @Test func commitReadsTheDiffIntoFiles() async throws {
        let diff = """
        diff --git a/a.txt b/b.txt
        similarity index 80%
        rename from a.txt
        rename to b.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/b.txt
        @@ -1 +1 @@
        -a
        +b
        diff --git a/new.md b/new.md
        new file mode 100644
        index 0000000..3333333
        --- /dev/null
        +++ b/new.md
        @@ -0,0 +1,2 @@
        +hello
        +world
        diff --git a/logo.png b/logo.png
        new file mode 100644
        index 0000000..4444444
        Binary files /dev/null and b/logo.png differ

        """
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"""
            {"hash":"abc","message":"Rename","date":"2026-11-20T08:45:00+00:00",
             "author":{"raw":"Mona <mona@example.com>"},"parents":[{"hash":"p"}]}
            """#.utf8)),
            HTTPResponse(statusCode: 200, body: Data(diff.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let detail = try await provider.commit(sha: "abc", repository: repositoryReference, context: authenticatedContext)

        #expect(detail.summary.sha == "abc")
        #expect(detail.summary.authorName == "Mona")
        #expect(detail.summary.parentSHAs == ["p"])
        #expect(detail.files.count == 3)
        #expect(detail.files[0].status == .renamed)
        #expect(detail.files[0].path == "b.txt")
        #expect(detail.files[0].previousPath == "a.txt")
        #expect(detail.files[0].patch == "@@ -1 +1 @@\n-a\n+b\n")
        #expect(detail.files[0].additions == 1)
        #expect(detail.files[0].deletions == 1)
        #expect(detail.files[1].status == .added)
        #expect(detail.files[1].path == "new.md")
        #expect(detail.files[1].additions == 2)
        #expect(detail.files[2].isBinary)
        #expect(detail.files[2].patch == nil)
        #expect(detail.filesTruncated == false)
        let requests = await client.requests
        #expect(requests.count == 2)
        #expect(requests[0].url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/commit/abc")
        #expect(requests[1].url.absoluteString == "https://api.bitbucket.org/2.0/repositories/workspace/repo/diff/abc")
        #expect(requests[1].headers["Authorization"] == "Bearer secret-token")
    }

    @Test func pullRequestsCarryStateAuthorAndDraft() async throws {
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: Data(#"""
            {"next":"https://api.bitbucket.org/2.0/repositories/workspace/repo/pullrequests?page=2","values":[
              {"id":7,"title":"Add dark mode","description":"Follows the system.","state":"MERGED",
               "author":{"display_name":"Alex"},"source":{"branch":{"name":"dark"}},"destination":{"branch":{"name":"main"}},
               "links":{"html":{"href":"https://bitbucket.org/workspace/repo/pull-requests/7"}},
               "created_on":"2026-11-19T10:00:00.000000+00:00","updated_on":"2026-11-21T10:00:00.654321+00:00"},
              {"id":8,"title":"WIP","description":"","state":"OPEN","draft":true,
               "source":{"branch":{"name":"wip"}},"destination":{"branch":{"name":"main"}}},
              {"id":9,"title":"Old idea","state":"DECLINED","source":{"branch":{"name":"old"}},"destination":{"branch":{"name":"main"}}},
              {"id":10,"title":"Replaced","state":"SUPERSEDED","source":{"branch":{"name":"rep"}},"destination":{"branch":{"name":"main"}}}
            ]}
            """#.utf8))
        ])
        let provider = BitbucketProvider(httpClient: client)

        let list = try await provider.pullRequests(
            GitPullRequestListQuery(repository: repositoryReference, filter: .all, page: 3, perPage: 25),
            context: authenticatedContext)

        #expect(list.items.map(\.state) == [.merged, .open, .closed, .closed])
        let merged = list.items[0]
        #expect(merged.id == "7")
        #expect(merged.number == 7)
        #expect(merged.title == "Add dark mode")
        #expect(merged.body == "Follows the system.")
        #expect(merged.authorName == "Alex")
        #expect(merged.sourceBranch == "dark")
        #expect(merged.targetBranch == "main")
        #expect(merged.webURL.absoluteString == "https://bitbucket.org/workspace/repo/pull-requests/7")
        #expect(merged.providerName == "Bitbucket")
        #expect(merged.isDraft == false)
        #expect(merged.createdAt == ISO8601DateFormatter().date(from: "2026-11-19T10:00:00Z"))
        #expect(merged.updatedAt != nil)
        #expect(list.items[1].isDraft)
        #expect(list.truncated)
        let url = try #require(await client.requests.first?.url)
        #expect(url.path == "/2.0/repositories/workspace/repo/pullrequests")
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(items.filter { $0.name == "state" }.compactMap(\.value) == ["OPEN", "MERGED", "DECLINED", "SUPERSEDED"])
        #expect(items.contains(URLQueryItem(name: "sort", value: "-updated_on")))
        #expect(items.contains(URLQueryItem(name: "pagelen", value: "25")))
        #expect(items.contains(URLQueryItem(name: "page", value: "3")))
    }

    @Test func pullRequestFiltersPickTheirStates() async throws {
        let empty = Data(#"{"values":[]}"#.utf8)
        let client = RecordingHTTPClient(responses: [
            HTTPResponse(statusCode: 200, body: empty),
            HTTPResponse(statusCode: 200, body: empty)
        ])
        let provider = BitbucketProvider(httpClient: client)

        _ = try await provider.pullRequests(GitPullRequestListQuery(repository: repositoryReference, filter: .open), context: authenticatedContext)
        let closed = try await provider.pullRequests(GitPullRequestListQuery(repository: repositoryReference, filter: .closed), context: authenticatedContext)

        #expect(closed.truncated == false)
        let states = await client.requests.map { request in
            (URLComponents(url: request.url, resolvingAgainstBaseURL: false)?.queryItems ?? []).filter { $0.name == "state" }.compactMap(\.value)
        }
        #expect(states == [["OPEN"], ["MERGED", "DECLINED", "SUPERSEDED"]])
    }

    @Test func providerAdvertisesHistoryCapabilities() {
        let provider = BitbucketProvider(httpClient: RecordingHTTPClient(responses: []))
        #expect(provider.capabilities.contains(.commitHistory))
        #expect(provider.capabilities.contains(.pullRequestList))
    }
}
