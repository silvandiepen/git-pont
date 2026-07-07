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
