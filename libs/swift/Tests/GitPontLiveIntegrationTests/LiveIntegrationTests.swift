import Foundation
import GitPontBitbucket
import GitPontCore
import GitPontForge
import GitPontGitHub
import GitPontGitLab
import Testing

@Suite("Live integration")
struct LiveIntegrationTests {
    @Test func githubAccountLoadsWhenTokenIsConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_GITHUB_TOKEN") else {
            return
        }

        let provider = GitHubProvider(httpClient: URLSessionHTTPClient())
        let account = try await provider.account(instance: .github, credential: GitCredential(accessToken: token))

        #expect(!account.id.isEmpty)
        #expect(!account.login.isEmpty)
    }

    @Test func gitLabAccountLoadsWhenTokenIsConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_GITLAB_TOKEN") else {
            return
        }

        let provider = GitLabProvider(httpClient: URLSessionHTTPClient())
        let account = try await provider.account(instance: .gitLabCloud, credential: GitCredential(accessToken: token))

        #expect(!account.id.isEmpty)
        #expect(!account.login.isEmpty)
    }

    @Test func forgeAccountLoadsWhenTokenIsConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_FORGEJO_TOKEN") else {
            return
        }
        let instance = environment("GITPONT_LIVE_FORGEJO_BASE_URL")
            .flatMap(URL.init(string:))
            .map { GitProviderInstance.forgejo(baseURL: $0) } ?? .codeberg

        let provider = ForgeProvider(httpClient: URLSessionHTTPClient(), instances: [instance])
        let account = try await provider.account(instance: instance, credential: GitCredential(accessToken: token))

        #expect(!account.id.isEmpty)
        #expect(!account.login.isEmpty)
    }

    @Test func bitbucketAccountLoadsWhenTokenIsConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_BITBUCKET_TOKEN") else {
            return
        }

        let provider = BitbucketProvider(httpClient: URLSessionHTTPClient())
        let account = try await provider.account(instance: .bitbucketCloud, credential: GitCredential(accessToken: token))

        #expect(!account.id.isEmpty)
        #expect(!account.login.isEmpty)
    }

    @Test func githubDisposableWriteCycleWhenConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_GITHUB_TOKEN"),
              let repository = repositoryReference(from: environment("GITPONT_LIVE_GITHUB_WRITE_REPO"), instance: .github)
        else {
            return
        }

        try await runDisposableWriteCycle(
            provider: GitHubProvider(httpClient: URLSessionHTTPClient()),
            repository: repository,
            token: token,
            baseRef: environment("GITPONT_LIVE_GITHUB_WRITE_BASE_REF") ?? repository.defaultBranch ?? "main"
        )
    }

    @Test func gitLabDisposableWriteCycleWhenConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_GITLAB_TOKEN"),
              let repository = repositoryReference(from: environment("GITPONT_LIVE_GITLAB_WRITE_REPO"), instance: .gitLabCloud)
        else {
            return
        }

        try await runDisposableWriteCycle(
            provider: GitLabProvider(httpClient: URLSessionHTTPClient()),
            repository: repository,
            token: token,
            baseRef: environment("GITPONT_LIVE_GITLAB_WRITE_BASE_REF") ?? repository.defaultBranch ?? "main"
        )
    }

    @Test func forgeDisposableWriteCycleWhenConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_FORGEJO_TOKEN") else {
            return
        }
        let instance = environment("GITPONT_LIVE_FORGEJO_BASE_URL")
            .flatMap(URL.init(string:))
            .map { GitProviderInstance.forgejo(baseURL: $0) } ?? .codeberg
        guard let repository = repositoryReference(from: environment("GITPONT_LIVE_FORGEJO_WRITE_REPO"), instance: instance) else {
            return
        }

        try await runDisposableWriteCycle(
            provider: ForgeProvider(httpClient: URLSessionHTTPClient(), instances: [instance]),
            repository: repository,
            token: token,
            baseRef: environment("GITPONT_LIVE_FORGEJO_WRITE_BASE_REF") ?? repository.defaultBranch ?? "main"
        )
    }

    @Test func bitbucketDisposableWriteCycleWhenConfigured() async throws {
        guard let token = environment("GITPONT_LIVE_BITBUCKET_TOKEN"),
              let repository = repositoryReference(from: environment("GITPONT_LIVE_BITBUCKET_WRITE_REPO"), instance: .bitbucketCloud)
        else {
            return
        }

        try await runDisposableWriteCycle(
            provider: BitbucketProvider(httpClient: URLSessionHTTPClient()),
            repository: repository,
            token: token,
            baseRef: environment("GITPONT_LIVE_BITBUCKET_WRITE_BASE_REF") ?? repository.defaultBranch ?? "main"
        )
    }

    private func environment(_ name: String) -> String? {
        guard let value = ProcessInfo.processInfo.environment[name], !value.isEmpty else {
            return nil
        }
        return value
    }

    private func repositoryReference(from value: String?, instance: GitProviderInstance) -> GitRepositoryReference? {
        guard let value, let slash = value.lastIndex(of: "/"), slash != value.startIndex else {
            return nil
        }
        let namespace = String(value[..<slash])
        let nameStart = value.index(after: slash)
        guard nameStart < value.endIndex else {
            return nil
        }
        return GitRepositoryReference(
            instance: instance,
            namespace: namespace,
            name: String(value[nameStart...]),
            defaultBranch: nil,
            webURL: nil,
            cloneHTTPSURL: nil
        )
    }

    private func runDisposableWriteCycle(
        provider: any GitProvider,
        repository: GitRepositoryReference,
        token: String,
        baseRef: String
    ) async throws {
        let context = GitProviderRequestContext(
            connection: nil,
            credential: GitCredential(accessToken: token)
        )
        let suffix = UUID().uuidString.lowercased()
        let branchName = "git-pont-live-\(suffix)"
        let filePath = ".git-pont-live/\(suffix).txt"
        let content = Data("git-pont live write \(suffix)\n".utf8)
        var createdBranch = false

        do {
            _ = try await provider.createBranch(
                GitCreateBranchRequest(repository: repository, name: branchName, fromRef: baseRef),
                context: context
            )
            createdBranch = true

            let reference = GitFileReference(repository: repository, path: filePath, ref: branchName)
            let commit = try await provider.commitFile(
                GitFileChange(
                    reference: reference,
                    content: content,
                    message: "git-pont live write test",
                    targetBranch: branchName,
                    expectedVersion: nil,
                    allowBlindOverwrite: false
                ),
                context: context
            )
            #expect(!commit.commitSHA.isEmpty)

            let remote = try await provider.readFile(reference, context: context)
            #expect(remote.content == content)

            guard let version = remote.version else {
                throw GitPontError.invalidProviderResponse("Live write test file did not include a remote version")
            }

            let delete = try await provider.deleteFile(
                GitFileDeleteRequest(
                    reference: reference,
                    message: "git-pont live write cleanup",
                    targetBranch: branchName,
                    expectedVersion: version,
                    allowBlindOverwrite: false
                ),
                context: context
            )
            #expect(!delete.commitSHA.isEmpty)

            try await cleanupBranchIfNeeded(provider: provider, repository: repository, branchName: branchName, context: context, createdBranch: createdBranch)
        } catch {
            try await cleanupBranchIfNeeded(provider: provider, repository: repository, branchName: branchName, context: context, createdBranch: createdBranch)
            throw error
        }
    }

    private func cleanupBranchIfNeeded(
        provider: any GitProvider,
        repository: GitRepositoryReference,
        branchName: String,
        context: GitProviderRequestContext,
        createdBranch: Bool
    ) async throws {
        guard createdBranch else {
            return
        }
        do {
            try await provider.deleteBranch(
                GitDeleteBranchRequest(repository: repository, name: branchName),
                context: context
            )
        } catch let error as GitPontError {
            guard case .notFound = error else {
                throw error
            }
        }
    }
}
