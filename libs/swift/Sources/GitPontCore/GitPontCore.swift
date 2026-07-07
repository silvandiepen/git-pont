@_exported import Foundation

/// Facade for parsing URLs, resolving connections, and executing provider operations.
public final class GitPont: Sendable {
    private let providers: [any GitProvider]
    private let connectionStore: any ConnectionStore
    private let credentialStore: any CredentialStore
    private let httpClient: any HTTPClient
    private let refreshCoordinator = OAuthCredentialRefreshCoordinator()

    public init(
        providers: [any GitProvider],
        connectionStore: any ConnectionStore,
        credentialStore: any CredentialStore,
        httpClient: any HTTPClient
    ) {
        self.providers = providers
        self.connectionStore = connectionStore
        self.credentialStore = credentialStore
        self.httpClient = httpClient
    }

    public func parse(url: URL) throws -> GitURLParseResult {
        let matchingProviders = providers.filter { $0.canHandle(url: url) }
        guard let provider = matchingProviders.first else {
            throw GitPontError.unsupportedURL(url.absoluteString)
        }
        guard matchingProviders.count == 1 else {
            throw GitPontError.unsupportedURL("Multiple providers can handle \(url.host ?? url.absoluteString)")
        }
        return try provider.parse(url: url)
    }

    public func resolve(_ result: GitURLParseResult) async throws -> GitURLReference {
        switch result {
        case .resolved(let reference):
            return reference
        case .ambiguous(let candidates):
            guard let first = candidates.first else {
                throw GitPontError.unsupportedURL("No URL candidates")
            }
            let repository = GitRepositoryReference(
                instance: first.instance,
                namespace: first.namespace,
                name: first.name,
                defaultBranch: nil,
                webURL: nil,
                cloneHTTPSURL: nil
            )
            let branchNames = try await branches(of: repository).items.map(\.name)
            if let match = candidates.first(where: { candidate in
                guard let ref = candidate.ref else { return false }
                return branchNames.contains(ref)
            }) {
                return match
            }
            throw GitPontError.unsupportedURL("No candidate matched a repository branch")
        }
    }

    public func openFile(from url: URL) async throws -> GitRemoteFile {
        let resolved = try await resolve(parse(url: url))
        guard let ref = resolved.ref, let path = resolved.path else {
            throw GitPontError.unsupportedURL("URL does not reference a file")
        }
        let repository = GitRepositoryReference(
            instance: resolved.instance,
            namespace: resolved.namespace,
            name: resolved.name,
            defaultBranch: nil,
            webURL: nil,
            cloneHTTPSURL: nil
        )
        return try await readFile(GitFileReference(repository: repository, path: path, ref: ref, webURL: nil))
    }

    public func readFile(_ reference: GitFileReference) async throws -> GitRemoteFile {
        let provider = try provider(for: reference.repository.instance)
        let context = try await optionalContext(for: reference.repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.readFile(reference, context: $0)
        }
    }

    public func listDirectory(_ reference: GitFileReference) async throws -> GitList<GitDirectoryEntry> {
        let provider = try provider(for: reference.repository.instance)
        let context = try await optionalContext(for: reference.repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.listDirectory(reference, context: $0)
        }
    }

    public func commitFile(_ change: GitFileChange) async throws -> GitCommitResult {
        try GitPontValidator.validate(change: change)
        let provider = try provider(for: change.reference.repository.instance)
        let context = try await requiredContext(for: change.reference.repository.instance)
        try await ensureSafeNonBlindWrite(change, provider: provider, context: context, repository: change.reference.repository, ref: change.targetBranch)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.commitFile(change, context: $0)
        }
    }

    public func deleteFile(_ request: GitFileDeleteRequest) async throws -> GitCommitResult {
        try GitPontValidator.validate(delete: request)
        let provider = try provider(for: request.reference.repository.instance)
        let context = try await requiredContext(for: request.reference.repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.deleteFile(request, context: $0)
        }
    }

    public func checkForRemoteChange(_ file: GitRemoteFile) async throws -> Bool {
        let remote = try await readFile(file.reference)
        return remote.version != file.version
    }

    public func repositories(connectionID: String) async throws -> GitList<GitRepository> {
        guard let connection = try await connectionStore.connection(id: connectionID) else {
            throw GitPontError.missingConnection(.github)
        }
        let provider = try provider(for: connection.instance)
        let context = try await context(for: connection)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.repositories(context: $0)
        }
    }

    public func repository(_ reference: GitRepositoryReference) async throws -> GitRepository {
        let provider = try provider(for: reference.instance)
        let context = try await optionalContext(for: reference.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.repository(reference, context: $0)
        }
    }

    public func branches(of repository: GitRepositoryReference) async throws -> GitList<GitBranch> {
        let provider = try provider(for: repository.instance)
        let context = try await optionalContext(for: repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.branches(repository: repository, context: $0)
        }
    }

    public func createRepository(_ request: GitCreateRepositoryRequest, connectionID: String) async throws -> GitRepository {
        guard let connection = try await connectionStore.connection(id: connectionID) else {
            throw GitPontError.missingConnection(.github)
        }
        let provider = try provider(for: connection.instance)
        let context = try await context(for: connection)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.createRepository(request, context: $0)
        }
    }

    public func createBranch(_ request: GitCreateBranchRequest) async throws -> GitBranch {
        let provider = try provider(for: request.repository.instance)
        let context = try await requiredContext(for: request.repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.createBranch(request, context: $0)
        }
    }

    public func deleteBranch(_ request: GitDeleteBranchRequest) async throws {
        let provider = try provider(for: request.repository.instance)
        let context = try await requiredContext(for: request.repository.instance)
        try await retryingAuthentication(provider: provider, context: context) {
            try await provider.deleteBranch(request, context: $0)
        }
    }

    public func startOAuth(_ request: GitOAuthStartRequest) async throws -> GitOAuthStartResult {
        try await authenticationProvider(for: request.instance).startOAuth(request)
    }

    public func completeOAuth(_ request: GitOAuthCompletionRequest) async throws -> GitCredential {
        try await authenticationProvider(for: request.instance).completeOAuth(request)
    }

    public func forkRepository(_ reference: GitRepositoryReference, connectionID: String) async throws -> GitRepository {
        guard let connection = try await connectionStore.connection(id: connectionID) else {
            throw GitPontError.missingConnection(reference.instance.kind)
        }
        let provider = try provider(for: reference.instance)
        let context = try await context(for: connection)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.forkRepository(reference, context: $0)
        }
    }

    public func createPullRequest(_ request: GitPullRequestRequest) async throws -> GitPullRequest {
        let provider = try provider(for: request.repository.instance)
        let context = try await requiredContext(for: request.repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.createPullRequest(request, context: $0)
        }
    }

    public func findPullRequest(_ query: GitPullRequestQuery) async throws -> GitPullRequest? {
        let provider = try provider(for: query.repository.instance)
        let context = try await requiredContext(for: query.repository.instance)
        return try await retryingAuthentication(provider: provider, context: context) {
            try await provider.findPullRequest(query, context: $0)
        }
    }

    public func submitChange(_ submission: GitChangeSubmission) async throws -> GitChangeResult {
        switch submission.strategy {
        case .directCommit:
            let commit = try await commitFile(submission.change)
            return GitChangeResult(
                commit: commit,
                pullRequest: nil,
                usedRepository: submission.change.reference.repository,
                usedBranch: commit.branch
            )
        case .existingBranch(let branchName):
            return try await submitExistingBranchCommit(submission.change, branchName: branchName)
        case .branchAndPullRequest(let branchName, let title, let body, let draft):
            return try await submitBranchPullRequest(
                submission.change,
                branchName: branchName,
                title: title,
                body: body,
                draft: draft
            )
        case .forkAndPullRequest(let branchName, let title, let body, let draft):
            return try await submitForkPullRequest(
                submission.change,
                branchName: branchName,
                title: title,
                body: body,
                draft: draft
            )
        case .automatic(let branchName, let title, let body, let draft):
            if try await canDirectCommit(to: submission.change.reference.repository, branch: submission.change.reference.ref) {
                let commit = try await commitFile(submission.change)
                return GitChangeResult(
                    commit: commit,
                    pullRequest: nil,
                    usedRepository: submission.change.reference.repository,
                    usedBranch: commit.branch
                )
            }

            let repository = try await repository(submission.change.reference.repository)
            if repository.permissions.canPush {
                return try await submitBranchPullRequest(
                    submission.change,
                    branchName: branchName,
                    title: title,
                    body: body,
                    draft: draft
                )
            }

            return try await submitForkPullRequest(
                submission.change,
                branchName: branchName,
                title: title,
                body: body,
                draft: draft
            )
        }
    }

    public func connections() async throws -> [GitConnection] {
        try await connectionStore.connections()
    }

    public func connection(for instance: GitProviderInstance, preferredConnectionID: String?) async throws -> GitConnection {
        try await requiredConnection(for: instance, preferredConnectionID: preferredConnectionID)
    }

    @discardableResult
    public func addConnection(instance: GitProviderInstance, credential: GitCredential, authMethod: GitAuthMethod) async throws -> GitConnection {
        let account = try await provider(for: instance).account(instance: instance, credential: credential)
        let now = Date()
        let connection = GitConnection(
            id: UUID().uuidString,
            instance: instance,
            accountID: account.id,
            accountLogin: account.login,
            displayName: account.displayName,
            authMethod: authMethod,
            createdAt: now,
            updatedAt: now
        )
        try await connectionStore.save(connection)
        try await credentialStore.save(credential, for: connection.id)
        return connection
    }

    public func removeConnection(id: String) async throws {
        try await connectionStore.delete(id: id)
        try await credentialStore.deleteCredential(for: id)
    }

    public func credential(for connectionID: String) async throws -> GitCredential? {
        guard let credential = try await credentialStore.loadCredential(for: connectionID) else {
            return nil
        }
        guard credential.shouldRefresh else {
            return credential
        }
        guard let connection = try await connectionStore.connection(id: connectionID) else {
            return credential
        }
        let provider = try provider(for: connection.instance)
        return try await refreshedCredentialIfNeeded(credential, connection: connection, provider: provider)
    }

    public func provider(for instance: GitProviderInstance) throws -> any GitProvider {
        guard let provider = providers.first(where: { providerMatches($0, instance: instance) }) else {
            throw GitPontError.unsupportedCapability("No provider registered for \(instance.kind.rawValue)")
        }
        return provider
    }

    private func providerMatches(_ provider: any GitProvider, instance: GitProviderInstance) -> Bool {
        if provider.kind == instance.kind || provider.canHandle(url: instance.baseURL) {
            return true
        }
        switch (provider.kind, instance.kind) {
        case (.gitLabCloud, .gitLabSelfHosted),
             (.gitLabSelfHosted, .gitLabCloud),
             (.forgejo, .gitea),
             (.gitea, .forgejo):
            return true
        default:
            return false
        }
    }

    private func authenticationProvider(for instance: GitProviderInstance) throws -> any GitAuthenticationProvider {
        let provider = try provider(for: instance)
        guard let authenticationProvider = provider as? any GitAuthenticationProvider else {
            throw GitPontError.unsupportedCapability("Provider does not support OAuth")
        }
        return authenticationProvider
    }

    private func optionalConnection(for instance: GitProviderInstance) async throws -> GitConnection? {
        let matches = try await connectionStore.connections().filter { $0.instance.id == instance.id }
        return matches.count == 1 ? matches[0] : nil
    }

    private func optionalContext(for instance: GitProviderInstance) async throws -> GitProviderRequestContext {
        guard let connection = try await optionalConnection(for: instance) else {
            return GitProviderRequestContext(connection: nil, credential: nil)
        }
        return try await context(for: connection)
    }

    private func requiredContext(for instance: GitProviderInstance, preferredConnectionID: String? = nil) async throws -> GitProviderRequestContext {
        let connection = try await requiredConnection(for: instance, preferredConnectionID: preferredConnectionID)
        return try await context(for: connection)
    }

    private func context(for connection: GitConnection) async throws -> GitProviderRequestContext {
        guard let credential = try await credential(for: connection.id) else {
            throw GitPontError.authenticationRequired
        }
        return GitProviderRequestContext(connection: connection, credential: credential)
    }

    private func requiredConnection(for instance: GitProviderInstance, preferredConnectionID: String? = nil) async throws -> GitConnection {
        let all = try await connectionStore.connections().filter { $0.instance.id == instance.id }
        if let preferredConnectionID {
            guard let connection = all.first(where: { $0.id == preferredConnectionID }) else {
                throw GitPontError.missingConnection(instance.kind)
            }
            return connection
        }
        switch all.count {
        case 1:
            return all[0]
        case 0:
            throw GitPontError.missingConnection(instance.kind)
        default:
            throw GitPontError.ambiguousConnection(instanceID: instance.id, candidates: all)
        }
    }

    private func refreshedCredentialIfNeeded(
        _ credential: GitCredential,
        connection: GitConnection,
        provider: any GitProvider,
        force: Bool = false
    ) async throws -> GitCredential {
        guard force || credential.shouldRefresh else {
            return credential
        }
        guard let authProvider = provider as? any GitAuthenticationProvider else {
            throw GitPontError.unsupportedCapability("Provider does not support OAuth refresh")
        }
        let refreshed = try await refreshCoordinator.refresh(connectionID: connection.id) {
            try await authProvider.refreshCredential(credential, instance: connection.instance)
        }
        try await credentialStore.save(refreshed, for: connection.id)
        return refreshed
    }

    private func retryingAuthentication<T>(
        provider: any GitProvider,
        context: GitProviderRequestContext,
        operation: (GitProviderRequestContext) async throws -> T
    ) async throws -> T {
        do {
            return try await operation(context)
        } catch let error as GitPontError {
            guard case .authenticationFailed = error,
                  let connection = context.connection,
                  let credential = context.credential,
                  credential.refreshToken != nil
            else {
                throw error
            }
            let refreshed = try await refreshedCredentialIfNeeded(
                credential,
                connection: connection,
                provider: provider,
                force: true
            )
            return try await operation(GitProviderRequestContext(connection: connection, credential: refreshed))
        } catch {
            throw error
        }
    }

    private func submitBranchPullRequest(
        _ change: GitFileChange,
        branchName: String,
        title: String,
        body: String?,
        draft: Bool
    ) async throws -> GitChangeResult {
        let branchName = try normalizedBranchName(branchName)
        let targetBranch = change.reference.ref
        let provider = try provider(for: change.reference.repository.instance)
        let context = try await requiredContext(for: change.reference.repository.instance)
        try await ensureSafeNonBlindWrite(change, provider: provider, context: context, repository: change.reference.repository, ref: targetBranch)

        _ = try await provider.createBranch(
            GitCreateBranchRequest(repository: change.reference.repository, name: branchName, fromRef: targetBranch),
            context: context
        )

        let branchChange = change.retargeted(to: change.reference.repository, ref: branchName, targetBranch: branchName, baseBranch: targetBranch)
        let commit: GitCommitResult
        do {
            commit = try await provider.commitFile(branchChange, context: context)
        } catch {
            throw partialSubmission(
                repository: change.reference.repository,
                branch: branchName,
                failure: error
            )
        }

        let pullRequest: GitPullRequest
        do {
            pullRequest = try await provider.createPullRequest(
                GitPullRequestRequest(
                    repository: change.reference.repository,
                    title: title,
                    body: body,
                    sourceBranch: branchName,
                    sourceRepository: nil,
                    targetBranch: targetBranch,
                    draft: draft
                ),
                context: context
            )
        } catch {
            throw partialSubmission(
                commit: commit,
                repository: change.reference.repository,
                branch: branchName,
                failure: error
            )
        }

        return GitChangeResult(
            commit: commit,
            pullRequest: pullRequest,
            usedRepository: change.reference.repository,
            usedBranch: branchName
        )
    }

    private func submitExistingBranchCommit(
        _ change: GitFileChange,
        branchName: String
    ) async throws -> GitChangeResult {
        let branchName = try normalizedBranchName(branchName)
        let provider = try provider(for: change.reference.repository.instance)
        let context = try await requiredContext(for: change.reference.repository.instance)
        try await ensureSafeNonBlindWrite(
            change,
            provider: provider,
            context: context,
            repository: change.reference.repository,
            ref: branchName
        )

        let branchChange = change.retargeted(
            to: change.reference.repository,
            ref: branchName,
            targetBranch: branchName,
            baseBranch: change.reference.ref
        )
        let commit = try await provider.commitFile(branchChange, context: context)
        return GitChangeResult(
            commit: commit,
            pullRequest: nil,
            usedRepository: change.reference.repository,
            usedBranch: branchName
        )
    }

    private func submitForkPullRequest(
        _ change: GitFileChange,
        branchName: String,
        title: String,
        body: String?,
        draft: Bool
    ) async throws -> GitChangeResult {
        let branchName = try normalizedBranchName(branchName)
        let targetBranch = change.reference.ref
        let provider = try provider(for: change.reference.repository.instance)
        let context = try await requiredContext(for: change.reference.repository.instance)
        let connection = try context.requiredConnection
        try await ensureSafeNonBlindWrite(change, provider: provider, context: context, repository: change.reference.repository, ref: targetBranch)
        let fork = try await forkRepository(change.reference.repository, connectionID: connection.id)

        do {
            _ = try await provider.createBranch(
                GitCreateBranchRequest(repository: fork.reference, name: branchName, fromRef: targetBranch),
                context: context
            )
        } catch {
            throw partialSubmission(
                repository: fork.reference,
                branch: branchName,
                failure: error
            )
        }

        let forkChange = change.retargeted(to: fork.reference, ref: branchName, targetBranch: branchName, baseBranch: targetBranch)
        let commit: GitCommitResult
        do {
            commit = try await provider.commitFile(forkChange, context: context)
        } catch {
            throw partialSubmission(
                repository: fork.reference,
                branch: branchName,
                failure: error
            )
        }

        let pullRequest: GitPullRequest
        do {
            pullRequest = try await provider.createPullRequest(
                GitPullRequestRequest(
                    repository: change.reference.repository,
                    title: title,
                    body: body,
                    sourceBranch: branchName,
                    sourceRepository: fork.reference,
                    targetBranch: targetBranch,
                    draft: draft
                ),
                context: context
            )
        } catch {
            throw partialSubmission(
                commit: commit,
                repository: fork.reference,
                branch: branchName,
                failure: error
            )
        }

        return GitChangeResult(
            commit: commit,
            pullRequest: pullRequest,
            usedRepository: fork.reference,
            usedBranch: branchName
        )
    }

    private func canDirectCommit(to reference: GitRepositoryReference, branch branchName: String) async throws -> Bool {
        let repository = try await repository(reference)
        guard repository.permissions.canPush else {
            return false
        }

        let branch = try await branches(of: reference).items.first { $0.name == branchName }
        return branch?.isProtected != true
    }

    private func normalizedBranchName(_ branchName: String) throws -> String {
        let trimmed = branchName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GitPontError.unsupportedURL("Branch name cannot be empty")
        }
        return trimmed
    }

    private func ensureSafeNonBlindWrite(
        _ change: GitFileChange,
        provider: any GitProvider,
        context: GitProviderRequestContext,
        repository: GitRepositoryReference,
        ref: String
    ) async throws {
        guard change.expectedVersion == nil, !change.allowBlindOverwrite else {
            return
        }

        let targetReference = GitFileReference(
            repository: repository,
            path: change.reference.path,
            ref: ref,
            webURL: change.reference.webURL
        )

        do {
            let remote = try await retryingAuthentication(provider: provider, context: context) {
                try await provider.readFile(targetReference, context: $0)
            }
            throw GitPontError.conflict(GitConflict(
                reference: targetReference,
                expectedVersion: nil,
                remoteVersion: remote.version,
                providerMessage: "Updating an existing file without an expected version requires allowBlindOverwrite"
            ))
        } catch let error as GitPontError {
            guard case .notFound = error else {
                throw error
            }
        }
    }

    private func partialSubmission(
        commit: GitCommitResult? = nil,
        repository: GitRepositoryReference,
        branch: String,
        failure: Error
    ) -> GitPontError {
        let completed = GitChangeResult(
            commit: commit ?? GitCommitResult(commitSHA: "", branch: branch),
            pullRequest: nil,
            usedRepository: repository,
            usedBranch: branch
        )
        return .partialSubmission(completed: completed, failure: String(describing: failure))
    }
}

private extension GitFileChange {
    func retargeted(to repository: GitRepositoryReference, ref: String, targetBranch: String, baseBranch: String) -> GitFileChange {
        GitFileChange(
            reference: GitFileReference(repository: repository, path: reference.path, ref: ref, webURL: reference.webURL),
            content: content,
            message: message,
            targetBranch: targetBranch,
            baseBranch: baseBranch,
            expectedVersion: expectedVersion,
            allowBlindOverwrite: allowBlindOverwrite,
            authorName: authorName,
            authorEmail: authorEmail
        )
    }
}

private actor OAuthCredentialRefreshCoordinator {
    private var tasks: [String: Task<GitCredential, Error>] = [:]

    func refresh(connectionID: String, operation: @escaping @Sendable () async throws -> GitCredential) async throws -> GitCredential {
        if let task = tasks[connectionID] {
            return try await task.value
        }

        let task = Task {
            try await operation()
        }
        tasks[connectionID] = task
        defer {
            tasks[connectionID] = nil
        }
        return try await task.value
    }
}

private extension GitCredential {
    var shouldRefresh: Bool {
        guard refreshToken != nil, let expiresAt else {
            return false
        }
        return expiresAt <= Date().addingTimeInterval(60)
    }
}

public extension GitPont {
    func commitFile(
        _ reference: GitFileReference,
        content: Data,
        message: String,
        expectedVersion: GitRemoteVersion?
    ) async throws -> GitCommitResult {
        try await commitFile(GitFileChange(
            reference: reference,
            content: content,
            message: message,
            targetBranch: reference.ref,
            baseBranch: nil,
            expectedVersion: expectedVersion,
            allowBlindOverwrite: false,
            authorName: nil,
            authorEmail: nil
        ))
    }
}
