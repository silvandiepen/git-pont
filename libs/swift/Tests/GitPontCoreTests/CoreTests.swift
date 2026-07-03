import Foundation
import Testing
@testable import GitPontCore

@Suite("Core")
struct CoreTests {
    @Test func inMemoryStoresSaveLoadAndDelete() async throws {
        let connections = InMemoryConnectionStore()
        let credentials = InMemoryCredentialStore()
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
        let credential = GitCredential(accessToken: "secret", scopes: ["repo"])

        await connections.save(connection)
        await credentials.save(credential, for: connection.id)

        #expect(await connections.connection(id: connection.id) == connection)
        #expect(await credentials.loadCredential(for: connection.id) == credential)

        await connections.delete(id: connection.id)
        await credentials.deleteCredential(for: connection.id)

        #expect(await connections.connection(id: connection.id) == nil)
        #expect(await credentials.loadCredential(for: connection.id) == nil)
    }

    @Test func connectionJSONDoesNotContainToken() throws {
        let connection = GitConnection(
            id: "connection-1",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .personalAccessToken,
            createdAt: Date(timeIntervalSince1970: 0),
            updatedAt: Date(timeIntervalSince1970: 0)
        )

        let data = try JSONEncoder().encode(connection)
        let json = String(decoding: data, as: UTF8.self)
        #expect(!json.contains("secret-token"))
    }

    @Test func invalidPathsAreRejected() throws {
        #expect(throws: GitPontError.self) {
            try GitPontValidator.validateRepositoryPath("../secret")
        }
        #expect(throws: GitPontError.self) {
            try GitPontValidator.validateRepositoryPath("/absolute")
        }
    }

    @Test func emptyCommitMessagesAreRejected() throws {
        var change = makeChange()
        change.message = "  \n"

        #expect(throws: GitPontError.self) {
            try GitPontValidator.validate(change: change)
        }
    }

    @Test func deleteWithoutExpectedVersionRequiresExplicitBlindOverwrite() throws {
        let request = GitFileDeleteRequest(
            reference: makeChange().reference,
            message: "Delete README",
            targetBranch: "main",
            expectedVersion: nil,
            allowBlindOverwrite: false
        )

        #expect(throws: GitPontError.self) {
            try GitPontValidator.validate(delete: request)
        }
    }

    @Test func commitWithoutExpectedVersionConflictsWhenRemoteFileExists() async throws {
        let provider = CommitSafetyProvider(remoteFileExists: true)
        let gitPont = await makeGitPont(provider: provider)
        var change = makeChange()
        change.expectedVersion = nil

        do {
            _ = try await gitPont.commitFile(change)
            Issue.record("Expected conflict")
        } catch let error as GitPontError {
            guard case .conflict(let conflict) = error else {
                Issue.record("Expected conflict, got \(error)")
                return
            }
            #expect(conflict.reference.path == "README.md")
            #expect(conflict.reference.ref == "main")
            #expect(conflict.remoteVersion == .blobSHA("remote"))
        }

        #expect(await provider.readReferences.map(\.ref) == ["main"])
        #expect(await provider.commitAttempts == 0)
    }

    @Test func commitWithoutExpectedVersionCreatesWhenRemoteFileIsMissing() async throws {
        let provider = CommitSafetyProvider(remoteFileExists: false)
        let gitPont = await makeGitPont(provider: provider)
        var change = makeChange()
        change.expectedVersion = nil

        let result = try await gitPont.commitFile(change)

        #expect(result.commitSHA == "commit-1")
        #expect(await provider.readReferences.map(\.path) == ["README.md"])
        #expect(await provider.commitAttempts == 1)
    }

    @Test func blindOverwriteSkipsCreateSafetyPreflight() async throws {
        let provider = CommitSafetyProvider(remoteFileExists: true)
        let gitPont = await makeGitPont(provider: provider)
        var change = makeChange()
        change.expectedVersion = nil
        change.allowBlindOverwrite = true

        let result = try await gitPont.commitFile(change)

        #expect(result.commitSHA == "commit-1")
        #expect(await provider.readReferences.isEmpty)
        #expect(await provider.commitAttempts == 1)
    }

    @Test func submitChangeBranchAndPullRequestCreatesBranchCommitAndPullRequest() async throws {
        let provider = SubmitChangeProvider(canPush: true, targetBranchProtected: true)
        let gitPont = await makeGitPont(provider: provider)
        let change = makeChange()

        let result = try await gitPont.submitChange(GitChangeSubmission(
            change: change,
            strategy: .branchAndPullRequest(branchName: "edit/readme", title: "Update README", body: "Body", draft: true)
        ))

        let calls = await provider.snapshot()
        #expect(calls.createdBranches.map(\.name) == ["edit/readme"])
        #expect(calls.createdBranches.first?.fromRef == "main")
        #expect(calls.commits.map(\.targetBranch) == ["edit/readme"])
        #expect(calls.pullRequests.first?.repository == change.reference.repository)
        #expect(calls.pullRequests.first?.sourceRepository == nil)
        #expect(calls.pullRequests.first?.targetBranch == "main")
        #expect(result.usedBranch == "edit/readme")
        #expect(result.pullRequest?.title == "Update README")
    }

    @Test func submitChangeForkAndPullRequestCommitsToForkAndOpensPullRequestOnUpstream() async throws {
        let provider = SubmitChangeProvider(canPush: false, targetBranchProtected: false)
        let gitPont = await makeGitPont(provider: provider)
        let change = makeChange()

        let result = try await gitPont.submitChange(GitChangeSubmission(
            change: change,
            strategy: .forkAndPullRequest(branchName: "fork/readme", title: "Fork update", body: nil, draft: false)
        ))

        let calls = await provider.snapshot()
        #expect(calls.forks == [change.reference.repository])
        #expect(calls.createdBranches.first?.repository.namespace == "octocat-fork")
        #expect(calls.commits.first?.reference.repository.namespace == "octocat-fork")
        #expect(calls.pullRequests.first?.repository == change.reference.repository)
        #expect(calls.pullRequests.first?.sourceRepository?.namespace == "octocat-fork")
        #expect(result.usedRepository.namespace == "octocat-fork")
        #expect(result.pullRequest?.sourceBranch == "fork/readme")
    }

    @Test func submitChangeAutomaticChoosesDirectCommitWhenPushAllowedAndBranchUnprotected() async throws {
        let provider = SubmitChangeProvider(canPush: true, targetBranchProtected: false)
        let gitPont = await makeGitPont(provider: provider)

        let result = try await gitPont.submitChange(GitChangeSubmission(
            change: makeChange(),
            strategy: .automatic(branchName: "unused", title: "Unused", body: nil, draft: false)
        ))

        let calls = await provider.snapshot()
        #expect(calls.createdBranches.isEmpty)
        #expect(calls.forks.isEmpty)
        #expect(calls.pullRequests.isEmpty)
        #expect(calls.commits.map(\.targetBranch) == ["main"])
        #expect(result.pullRequest == nil)
    }

    @Test func submitChangeAutomaticChoosesBranchPullRequestForProtectedPushBranch() async throws {
        let provider = SubmitChangeProvider(canPush: true, targetBranchProtected: true)
        let gitPont = await makeGitPont(provider: provider)

        let result = try await gitPont.submitChange(GitChangeSubmission(
            change: makeChange(),
            strategy: .automatic(branchName: "protected/edit", title: "Protected update", body: nil, draft: false)
        ))

        let calls = await provider.snapshot()
        #expect(calls.forks.isEmpty)
        #expect(calls.createdBranches.map(\.name) == ["protected/edit"])
        #expect(calls.pullRequests.first?.sourceRepository == nil)
        #expect(result.pullRequest?.title == "Protected update")
    }

    @Test func submitChangeAutomaticChoosesForkPullRequestWhenPushIsNotAllowed() async throws {
        let provider = SubmitChangeProvider(canPush: false, targetBranchProtected: false)
        let gitPont = await makeGitPont(provider: provider)

        _ = try await gitPont.submitChange(GitChangeSubmission(
            change: makeChange(),
            strategy: .automatic(branchName: "fork/edit", title: "Fork update", body: nil, draft: false)
        ))

        let calls = await provider.snapshot()
        #expect(calls.forks.count == 1)
        #expect(calls.createdBranches.first?.repository.namespace == "octocat-fork")
        #expect(calls.pullRequests.first?.sourceRepository?.namespace == "octocat-fork")
    }

    @Test func submitChangeBranchPullRequestCommitFailureReturnsPartialSubmission() async throws {
        let provider = SubmitChangeProvider(canPush: true, targetBranchProtected: true, failCommits: true)
        let gitPont = await makeGitPont(provider: provider)

        do {
            _ = try await gitPont.submitChange(GitChangeSubmission(
                change: makeChange(),
                strategy: .branchAndPullRequest(branchName: "partial/edit", title: "Partial", body: nil, draft: false)
            ))
            Issue.record("Expected partial submission")
        } catch let error as GitPontError {
            guard case .partialSubmission(let completed, let failure) = error else {
                Issue.record("Expected partial submission, got \(error)")
                return
            }
            #expect(completed.usedBranch == "partial/edit")
            #expect(completed.usedRepository.namespace == "octocat")
            #expect(completed.commit.commitSHA == "")
            #expect(failure.contains("Commit failed"))
        }
    }

    @Test func submitChangeBranchPullRequestPRFailureReturnsCompletedCommit() async throws {
        let provider = SubmitChangeProvider(canPush: true, targetBranchProtected: true, failPullRequests: true)
        let gitPont = await makeGitPont(provider: provider)

        do {
            _ = try await gitPont.submitChange(GitChangeSubmission(
                change: makeChange(),
                strategy: .branchAndPullRequest(branchName: "partial/pr", title: "Partial", body: nil, draft: false)
            ))
            Issue.record("Expected partial submission")
        } catch let error as GitPontError {
            guard case .partialSubmission(let completed, let failure) = error else {
                Issue.record("Expected partial submission, got \(error)")
                return
            }
            #expect(completed.usedBranch == "partial/pr")
            #expect(completed.commit.commitSHA == "commit-1")
            #expect(failure.contains("Pull request failed"))
        }
    }

    @Test func expiringOAuthCredentialRefreshesBeforeProviderRequest() async throws {
        let provider = RefreshingProvider()
        let stores = await makeOAuthGitPont(provider: provider)

        _ = try await stores.gitPont.commitFile(makeChange())

        #expect(await provider.refreshCount == 1)
        #expect(await provider.commitTokens == ["fresh-token"])
        #expect(await stores.credentials.loadCredential(for: "connection-1")?.accessToken == "fresh-token")
    }

    @Test func concurrentRequestsShareOneCredentialRefresh() async throws {
        let provider = RefreshingProvider(refreshDelay: .milliseconds(50))
        let stores = await makeOAuthGitPont(provider: provider)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<5 {
                group.addTask {
                    _ = try await stores.gitPont.commitFile(makeChange())
                }
            }
            try await group.waitForAll()
        }

        #expect(await provider.refreshCount == 1)
        #expect(await provider.commitTokens == Array(repeating: "fresh-token", count: 5))
    }

    @Test func authenticationFailureRefreshesAndRetriesOnce() async throws {
        let provider = RefreshingProvider(failFirstCommitWithAuthenticationFailure: true)
        let stores = await makeOAuthGitPont(
            provider: provider,
            expiresAt: Date(timeIntervalSinceNow: 3600)
        )

        let result = try await stores.gitPont.commitFile(makeChange())

        #expect(result.commitSHA == "commit-1")
        #expect(await provider.refreshCount == 1)
        #expect(await provider.commitAttempts == 2)
        #expect(await provider.commitTokens == ["fresh-token"])
        #expect(await stores.credentials.loadCredential(for: "connection-1")?.accessToken == "fresh-token")
    }

    @Test func facadeStartsAndCompletesOAuthThroughMatchingProvider() async throws {
        let provider = RefreshingProvider()
        let stores = await makeOAuthGitPont(provider: provider)
        let appConfig = OAuthAppConfig(
            clientID: "client-id",
            redirectURI: URL(string: "gitpont://oauth")!,
            scopes: ["repo"]
        )

        let start = try await stores.gitPont.startOAuth(GitOAuthStartRequest(
            instance: .github,
            method: .oauthPKCE,
            appConfig: appConfig
        ))
        guard case .browser(let session) = start else {
            Issue.record("Expected browser OAuth session")
            return
        }

        let credential = try await stores.gitPont.completeOAuth(GitOAuthCompletionRequest(
            instance: .github,
            method: .oauthPKCE,
            appConfig: appConfig,
            callbackURL: URL(string: "gitpont://oauth?code=returned&state=\(session.state)")!,
            state: session.state,
            codeVerifier: session.codeVerifier
        ))

        #expect(credential.accessToken == "oauth-access")
        #expect(await provider.oauthStartCount == 1)
        #expect(await provider.oauthCompleteCount == 1)
    }

    private func makeGitPont(provider: SubmitChangeProvider) async -> GitPont {
        let connections = InMemoryConnectionStore()
        let credentials = InMemoryCredentialStore()
        let now = Date(timeIntervalSince1970: 0)
        let connection = GitConnection(
            id: "connection-1",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .personalAccessToken,
            createdAt: now,
            updatedAt: now
        )
        await connections.save(connection)
        await credentials.save(GitCredential(accessToken: "secret", scopes: ["repo"]), for: connection.id)
        return GitPont(
            providers: [provider],
            connectionStore: connections,
            credentialStore: credentials,
            httpClient: NoopHTTPClient()
        )
    }

    private func makeGitPont(provider: CommitSafetyProvider) async -> GitPont {
        let connections = InMemoryConnectionStore()
        let credentials = InMemoryCredentialStore()
        let now = Date(timeIntervalSince1970: 0)
        let connection = GitConnection(
            id: "connection-1",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .personalAccessToken,
            createdAt: now,
            updatedAt: now
        )
        await connections.save(connection)
        await credentials.save(GitCredential(accessToken: "secret", scopes: ["repo"]), for: connection.id)
        return GitPont(
            providers: [provider],
            connectionStore: connections,
            credentialStore: credentials,
            httpClient: NoopHTTPClient()
        )
    }

    private func makeChange() -> GitFileChange {
        let repository = GitRepositoryReference(
            instance: .github,
            namespace: "octocat",
            name: "hello-world",
            defaultBranch: "main",
            webURL: URL(string: "https://github.com/octocat/hello-world"),
            cloneHTTPSURL: nil
        )
        return GitFileChange(
            reference: GitFileReference(repository: repository, path: "README.md", ref: "main"),
            content: Data("Hello".utf8),
            message: "Update README",
            targetBranch: "main",
            expectedVersion: .blobSHA("old"),
            allowBlindOverwrite: false
        )
    }

    private func makeOAuthGitPont(
        provider: RefreshingProvider,
        expiresAt: Date = Date(timeIntervalSinceNow: -10)
    ) async -> (gitPont: GitPont, credentials: InMemoryCredentialStore) {
        let connections = InMemoryConnectionStore()
        let credentials = InMemoryCredentialStore()
        let now = Date(timeIntervalSince1970: 0)
        let connection = GitConnection(
            id: "connection-1",
            instance: .github,
            accountID: "1",
            accountLogin: "octocat",
            authMethod: .oauthPKCE,
            createdAt: now,
            updatedAt: now
        )
        await connections.save(connection)
        await credentials.save(
            GitCredential(
                accessToken: "stale-token",
                refreshToken: "refresh-token",
                tokenType: "bearer",
                expiresAt: expiresAt,
                scopes: ["repo"]
            ),
            for: connection.id
        )
        let gitPont = GitPont(
            providers: [provider],
            connectionStore: connections,
            credentialStore: credentials,
            httpClient: NoopHTTPClient()
        )
        return (gitPont, credentials)
    }
}

private struct SubmitChangeSnapshot: Sendable {
    var createdBranches: [GitCreateBranchRequest]
    var commits: [GitFileChange]
    var forks: [GitRepositoryReference]
    var pullRequests: [GitPullRequestRequest]
}

private actor SubmitChangeProvider: GitProvider {
    nonisolated var kind: GitProviderKind { .github }
    nonisolated var displayName: String { "GitHub" }
    nonisolated var capabilities: GitProviderCapabilities {
        [.fileCommit, .branchCreate, .repositoryFork, .pullRequestCreate]
    }
    nonisolated var changeRequestTerm: GitChangeRequestTerm { .pullRequest }

    private let canPush: Bool
    private let targetBranchProtected: Bool
    private let failCommits: Bool
    private let failPullRequests: Bool
    private var createdBranches: [GitCreateBranchRequest] = []
    private var commits: [GitFileChange] = []
    private var forks: [GitRepositoryReference] = []
    private var pullRequests: [GitPullRequestRequest] = []

    init(canPush: Bool, targetBranchProtected: Bool, failCommits: Bool = false, failPullRequests: Bool = false) {
        self.canPush = canPush
        self.targetBranchProtected = targetBranchProtected
        self.failCommits = failCommits
        self.failPullRequests = failPullRequests
    }

    nonisolated func canHandle(url: URL) -> Bool {
        url.host == "github.com"
    }

    nonisolated func parse(url: URL) throws -> GitURLParseResult {
        throw GitPontError.unsupportedURL(url.absoluteString)
    }

    func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        GitAccount(id: "1", login: "octocat")
    }

    func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        GitList(items: [])
    }

    func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        GitRepository(
            reference: reference,
            isPrivate: false,
            isFork: false,
            permissions: GitRepositoryPermissions(canRead: true, canPush: canPush, canAdmin: false)
        )
    }

    func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        GitList(items: [
            GitBranch(name: "main", commitSHA: "base", isDefault: true, isProtected: targetBranchProtected)
        ])
    }

    func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        throw GitPontError.unsupportedCapability("readFile is not used in submitChange tests")
    }

    func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        throw GitPontError.unsupportedCapability("listDirectory is not used in submitChange tests")
    }

    func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        if failCommits {
            throw GitPontError.providerUnavailable("Commit failed")
        }
        commits.append(change)
        return GitCommitResult(commitSHA: "commit-\(commits.count)", branch: change.targetBranch, newVersion: .blobSHA("new"))
    }

    func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        throw GitPontError.unsupportedCapability("deleteFile is not used in submitChange tests")
    }

    func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        createdBranches.append(request)
        return GitBranch(name: request.name, commitSHA: "branch")
    }

    func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {}

    func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("createRepository is not used in submitChange tests")
    }

    func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        forks.append(reference)
        let forkReference = GitRepositoryReference(
            instance: reference.instance,
            namespace: "\(reference.namespace)-fork",
            name: reference.name,
            defaultBranch: reference.defaultBranch,
            webURL: URL(string: "https://github.com/\(reference.namespace)-fork/\(reference.name)"),
            cloneHTTPSURL: nil
        )
        return GitRepository(
            reference: forkReference,
            isPrivate: false,
            isFork: true,
            parent: reference,
            permissions: GitRepositoryPermissions(canRead: true, canPush: true, canAdmin: false)
        )
    }

    func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        if failPullRequests {
            throw GitPontError.providerUnavailable("Pull request failed")
        }
        pullRequests.append(request)
        return GitPullRequest(
            id: "1",
            number: pullRequests.count,
            title: request.title,
            webURL: URL(string: "https://github.com/octocat/hello-world/pull/\(pullRequests.count)")!,
            sourceBranch: request.sourceBranch,
            targetBranch: request.targetBranch,
            providerName: displayName
        )
    }

    func snapshot() -> SubmitChangeSnapshot {
        SubmitChangeSnapshot(
            createdBranches: createdBranches,
            commits: commits,
            forks: forks,
            pullRequests: pullRequests
        )
    }
}

private actor CommitSafetyProvider: GitProvider {
    nonisolated var kind: GitProviderKind { .github }
    nonisolated var displayName: String { "GitHub" }
    nonisolated var capabilities: GitProviderCapabilities { [.authenticatedFileRead, .fileCommit] }
    nonisolated var changeRequestTerm: GitChangeRequestTerm { .pullRequest }

    private let remoteFileExists: Bool
    private(set) var readReferences: [GitFileReference] = []
    private(set) var commitAttempts = 0

    init(remoteFileExists: Bool) {
        self.remoteFileExists = remoteFileExists
    }

    nonisolated func canHandle(url: URL) -> Bool {
        url.host == "github.com"
    }

    nonisolated func parse(url: URL) throws -> GitURLParseResult {
        throw GitPontError.unsupportedURL(url.absoluteString)
    }

    func account(instance: GitProviderInstance, credential: GitCredential) async throws -> GitAccount {
        GitAccount(id: "1", login: "octocat")
    }

    func repositories(context: GitProviderRequestContext) async throws -> GitList<GitRepository> {
        GitList(items: [])
    }

    func repository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        GitRepository(reference: reference, isPrivate: false, isFork: false, permissions: GitRepositoryPermissions(canRead: true, canPush: true, canAdmin: false))
    }

    func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        GitList(items: [])
    }

    func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        readReferences.append(reference)
        guard remoteFileExists else {
            throw GitPontError.notFound("Missing")
        }
        return GitRemoteFile(
            reference: reference,
            content: Data("Remote".utf8),
            encoding: .utf8,
            version: .blobSHA("remote")
        )
    }

    func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        throw GitPontError.unsupportedCapability("listDirectory is not used in commit safety tests")
    }

    func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        commitAttempts += 1
        return GitCommitResult(commitSHA: "commit-\(commitAttempts)", branch: change.targetBranch, newVersion: .blobSHA("new"))
    }

    func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        throw GitPontError.unsupportedCapability("deleteFile is not used in commit safety tests")
    }

    func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        throw GitPontError.unsupportedCapability("createBranch is not used in commit safety tests")
    }

    func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        throw GitPontError.unsupportedCapability("deleteBranch is not used in commit safety tests")
    }

    func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("createRepository is not used in commit safety tests")
    }

    func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("forkRepository is not used in commit safety tests")
    }

    func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        throw GitPontError.unsupportedCapability("createPullRequest is not used in commit safety tests")
    }
}

private actor RefreshingProvider: GitProvider, GitAuthenticationProvider {
    nonisolated var kind: GitProviderKind { .github }
    nonisolated var displayName: String { "GitHub" }
    nonisolated var capabilities: GitProviderCapabilities { [.fileCommit] }
    nonisolated var changeRequestTerm: GitChangeRequestTerm { .pullRequest }

    private let refreshDelay: Duration?
    private var authFailuresRemaining: Int
    private(set) var refreshCount = 0
    private(set) var commitAttempts = 0
    private(set) var commitTokens: [String] = []
    private(set) var oauthStartCount = 0
    private(set) var oauthCompleteCount = 0

    init(refreshDelay: Duration? = nil, failFirstCommitWithAuthenticationFailure: Bool = false) {
        self.refreshDelay = refreshDelay
        self.authFailuresRemaining = failFirstCommitWithAuthenticationFailure ? 1 : 0
    }

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
        oauthStartCount += 1
        return .browser(GitOAuthBrowserSession(
            authorizationURL: URL(string: "https://github.com/login/oauth/authorize?client_id=\(request.appConfig.clientID)")!,
            state: "state-\(oauthStartCount)",
            codeVerifier: "verifier-\(oauthStartCount)",
            redirectURI: request.appConfig.redirectURI ?? URL(string: "gitpont://oauth")!
        ))
    }

    func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential {
        oauthCompleteCount += 1
        return GitCredential(
            accessToken: "oauth-access",
            refreshToken: "oauth-refresh",
            tokenType: "bearer",
            expiresAt: Date(timeIntervalSinceNow: 3600),
            scopes: request.appConfig.scopes
        )
    }

    func refreshCredential(_ credential: GitCredential, instance: GitProviderInstance) async throws -> GitCredential {
        refreshCount += 1
        if let refreshDelay {
            try await Task.sleep(for: refreshDelay)
        }
        return GitCredential(
            accessToken: "fresh-token",
            refreshToken: credential.refreshToken,
            tokenType: credential.tokenType,
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
        GitRepository(reference: reference, isPrivate: false, isFork: false, permissions: GitRepositoryPermissions(canRead: true, canPush: true, canAdmin: false))
    }

    func branches(repository: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitList<GitBranch> {
        GitList(items: [])
    }

    func readFile(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitRemoteFile {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func listDirectory(_ reference: GitFileReference, context: GitProviderRequestContext) async throws -> GitList<GitDirectoryEntry> {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func commitFile(_ change: GitFileChange, context: GitProviderRequestContext) async throws -> GitCommitResult {
        commitAttempts += 1
        if authFailuresRemaining > 0 {
            authFailuresRemaining -= 1
            throw GitPontError.authenticationFailed("Expired")
        }
        commitTokens.append(try context.requiredCredential.accessToken)
        return GitCommitResult(commitSHA: "commit-\(commitTokens.count)", branch: change.targetBranch, newVersion: .blobSHA("new"))
    }

    func deleteFile(_ request: GitFileDeleteRequest, context: GitProviderRequestContext) async throws -> GitCommitResult {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func createBranch(_ request: GitCreateBranchRequest, context: GitProviderRequestContext) async throws -> GitBranch {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func deleteBranch(_ request: GitDeleteBranchRequest, context: GitProviderRequestContext) async throws {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func createRepository(_ request: GitCreateRepositoryRequest, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func forkRepository(_ reference: GitRepositoryReference, context: GitProviderRequestContext) async throws -> GitRepository {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }

    func createPullRequest(_ request: GitPullRequestRequest, context: GitProviderRequestContext) async throws -> GitPullRequest {
        throw GitPontError.unsupportedCapability("Not used in refresh tests")
    }
}

private struct NoopHTTPClient: HTTPClient {
    func send(_ request: HTTPRequest) async throws -> HTTPResponse {
        throw GitPontError.providerUnavailable("NoopHTTPClient does not send requests")
    }
}
