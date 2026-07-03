import Foundation
import Testing
import GitPontCore
import GitPontGitCLI

@Suite("Git CLI")
struct GitCLITests {
    @Test func contextDoesNotPutTokenInArguments() async throws {
        let connectionStore = InMemoryConnectionStore()
        let credentialStore = InMemoryCredentialStore()
        let now = Date()
        let connection = GitConnection(
            id: "connection-1",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .personalAccessToken,
            createdAt: now,
            updatedAt: now
        )
        await connectionStore.save(connection)
        await credentialStore.save(GitCredential(accessToken: "secret-token"), for: connection.id)

        let gitPont = GitPont(
            providers: [],
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            httpClient: MockHTTPClient()
        )

        let context = try await gitPont.gitCredentialContext(
            forRemoteURL: URL(string: "https://github.com/owner/repo.git")!,
            preferredConnectionID: connection.id
        )

        #expect(context.environment["GITPONT_TOKEN"] == "secret-token")
        #expect(context.environment["GIT_TERMINAL_PROMPT"] == "0")
        #expect(!context.argumentsPrefix.joined(separator: " ").contains("secret-token"))
    }

    @Test func customRemoteUsesConfiguredConnection() async throws {
        let connectionStore = InMemoryConnectionStore()
        let credentialStore = InMemoryCredentialStore()
        let instance = GitProviderInstance.gitLabSelfHosted(
            baseURL: URL(string: "https://gitlab.company.com")!,
            displayName: "Company GitLab"
        )
        let connection = GitConnection(
            id: "connection-2",
            instance: instance,
            accountID: "2",
            accountLogin: "dev",
            authMethod: .personalAccessToken,
            createdAt: Date(),
            updatedAt: Date()
        )
        await connectionStore.save(connection)
        await credentialStore.save(GitCredential(accessToken: "company-token"), for: connection.id)

        let gitPont = GitPont(
            providers: [],
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            httpClient: MockHTTPClient()
        )

        let context = try await gitPont.gitCredentialContext(
            forRemoteURL: URL(string: "https://gitlab.company.com/group/project.git")!,
            preferredConnectionID: connection.id
        )

        #expect(context.environment["GITPONT_USERNAME"] == "dev")
        #expect(context.environment["GITPONT_TOKEN"] == "company-token")
    }

    @Test func contextRefreshesExpiringOAuthCredential() async throws {
        let connectionStore = InMemoryConnectionStore()
        let credentialStore = InMemoryCredentialStore()
        let provider = RefreshingCLIProvider()
        let connection = GitConnection(
            id: "connection-3",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .oauthPKCE,
            createdAt: Date(),
            updatedAt: Date()
        )
        await connectionStore.save(connection)
        await credentialStore.save(
            GitCredential(
                accessToken: "stale-token",
                refreshToken: "refresh-token",
                expiresAt: Date(timeIntervalSinceNow: -1),
                scopes: ["repo"]
            ),
            for: connection.id
        )

        let gitPont = GitPont(
            providers: [provider],
            connectionStore: connectionStore,
            credentialStore: credentialStore,
            httpClient: MockHTTPClient()
        )

        let context = try await gitPont.gitCredentialContext(
            forRemoteURL: URL(string: "https://github.com/owner/repo.git")!,
            preferredConnectionID: connection.id
        )

        #expect(context.environment["GITPONT_TOKEN"] == "fresh-token")
        #expect(await provider.refreshCount == 1)
        #expect(await credentialStore.loadCredential(for: connection.id)?.accessToken == "fresh-token")
    }
}

private struct MockHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        HTTPResponse(statusCode: 200)
    }
}

private actor RefreshingCLIProvider: GitProvider, GitAuthenticationProvider {
    nonisolated var kind: GitProviderKind { .github }
    nonisolated var displayName: String { "GitHub" }
    nonisolated var capabilities: GitProviderCapabilities { [.gitCLICredentials] }
    nonisolated var changeRequestTerm: GitChangeRequestTerm { .pullRequest }

    private(set) var refreshCount = 0

    nonisolated func canHandle(url: URL) -> Bool {
        url.host == "github.com"
    }

    nonisolated func parse(url: URL) throws -> GitURLParseResult {
        throw GitPontError.unsupportedURL(url.absoluteString)
    }

    nonisolated func authorizationHeaders(for credential: GitCredential, authMethod: GitAuthMethod) throws -> [String: String] {
        ["Authorization": "Bearer \(credential.accessToken)"]
    }

    func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential {
        refreshCount += 1
        return GitCredential(
            accessToken: "fresh-token",
            refreshToken: credential.refreshToken,
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: credential.scopes
        )
    }

    func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        GitAccount(id: "1", login: "octocat")
    }

    func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        GitList(items: [])
    }

    func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }

    func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        throw GitPontError.unsupportedCapability("Not used in Git CLI tests")
    }
}
