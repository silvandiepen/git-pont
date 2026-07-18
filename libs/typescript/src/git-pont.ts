/**
 * `GitPont` facade — the app-facing entry point. Mirrors the canonical Swift
 * facade in `docs/content/architecture.md`. Resolves the provider and
 * connection for each call, refreshes credentials when needed (serialized per
 * connection), and delegates to the provider implementation.
 */

import { GitPontError } from "./errors.js";
import { defaultRetryPolicy, type RetryPolicy } from "./http.js";
import type {
  GitBranch,
  GitChangeResult,
  GitChangeSubmission,
  GitCommitResult,
  GitConnection,
  GitCreateBranchRequest,
  GitCreateRepositoryRequest,
  GitCredential,
  GitDeleteBranchRequest,
  GitDirectoryEntry,
  GitFileChange,
  GitFileDeleteRequest,
  GitFileReference,
  GitList,
  GitProviderInstance,
  GitProviderKind,
  GitPullRequest,
  GitPullRequestRequest,
  GitRemoteFile,
  GitRemoteVersion,
  GitRepository,
  GitRepositoryReference,
  GitURLParseResult,
  GitURLReference,
  GitAuthMethod,
} from "./models.js";
import type {
  GitOAuthCompletionRequest,
  GitOAuthStartRequest,
  GitOAuthStartResult,
} from "./oauth.js";
import {
  supportsAuthentication,
  type ConnectionStore,
  type CredentialStore,
  type GitAuthenticationProvider,
  type GitProvider,
  type GitProviderRequestContext,
} from "./protocols.js";

/** How much slack before expiry triggers a proactive token refresh (ms). */
const REFRESH_SKEW_MS = 60_000;

export interface GitPontOptions {
  providers: GitProvider[];
  connectionStore: ConnectionStore;
  credentialStore: CredentialStore;
  retryPolicy?: RetryPolicy;
  /** Injectable id generator (defaults to crypto.randomUUID). */
  generateID?: () => string;
}

type ProviderFamily = "github" | "gitlab" | "forge" | "bitbucket";

function familyOf(kind: GitProviderKind): ProviderFamily {
  switch (kind) {
    case "github":
      return "github";
    case "gitLabCloud":
    case "gitLabSelfHosted":
      return "gitlab";
    case "forgejo":
    case "gitea":
      return "forge";
    case "bitbucketCloud":
      return "bitbucket";
  }
}

export class GitPont {
  private readonly providers: GitProvider[];
  private readonly connectionStore: ConnectionStore;
  private readonly credentialStore: CredentialStore;
  private readonly retryPolicy: RetryPolicy;
  private readonly generateID: () => string;
  private readonly refreshInFlight = new Map<string, Promise<GitCredential>>();

  constructor(options: GitPontOptions) {
    this.providers = options.providers;
    this.connectionStore = options.connectionStore;
    this.credentialStore = options.credentialStore;
    this.retryPolicy = options.retryPolicy ?? defaultRetryPolicy();
    this.generateID = options.generateID ?? (() => globalThis.crypto.randomUUID());
  }

  // MARK: - URL handling

  parse(url: string): GitURLParseResult {
    return this.providerForURL(url).parse(url);
  }

  async resolve(result: GitURLParseResult): Promise<GitURLReference> {
    if (result.kind === "resolved") return result.reference;
    const candidates = result.candidates;
    const first = candidates[0];
    if (!first) throw GitPontError.unsupportedURL("ambiguous URL with no candidates");
    const repository = this.repositoryReferenceFrom(first);
    const context = await this.buildContext(first.instance, { allowNone: true });
    const branches = await this.providerForInstance(first.instance).branches(repository, context);
    const names = new Set(branches.items.map((b) => b.name));
    // Candidates are ordered longest-ref-first; take the first real branch match.
    for (const candidate of candidates) {
      if (candidate.ref && names.has(candidate.ref)) return candidate;
    }
    throw GitPontError.unsupportedURL("Could not resolve URL against repository branches");
  }

  async openFile(url: string): Promise<GitRemoteFile> {
    const reference = await this.resolve(this.parse(url));
    const repository = this.repositoryReferenceFrom(reference);
    const ref = reference.ref ?? (await this.defaultBranch(repository));
    const fileReference: GitFileReference = {
      repository,
      path: reference.path ?? "",
      ref,
    };
    return this.readFile(fileReference);
  }

  // MARK: - Files

  async readFile(reference: GitFileReference): Promise<GitRemoteFile> {
    return this.runMaybeAuthenticated(reference.repository.instance, (ctx) =>
      this.providerForInstance(reference.repository.instance).readFile(reference, ctx),
    );
  }

  async listDirectory(reference: GitFileReference): Promise<GitList<GitDirectoryEntry>> {
    return this.runMaybeAuthenticated(reference.repository.instance, (ctx) =>
      this.providerForInstance(reference.repository.instance).listDirectory(reference, ctx),
    );
  }

  async commitFile(change: GitFileChange): Promise<GitCommitResult> {
    return this.runAuthenticated(change.reference.repository.instance, (ctx) =>
      this.providerForInstance(change.reference.repository.instance).commitFile(change, ctx),
    );
  }

  async deleteFile(request: GitFileDeleteRequest): Promise<GitCommitResult> {
    return this.runAuthenticated(request.reference.repository.instance, (ctx) =>
      this.providerForInstance(request.reference.repository.instance).deleteFile(request, ctx),
    );
  }

  /** True when the remote version differs from the loaded file's version. */
  async checkForRemoteChange(file: GitRemoteFile): Promise<boolean> {
    const current = await this.readFile(file.reference);
    return !sameVersion(current.version, file.version);
  }

  // MARK: - Repositories and branches

  async repositories(connectionID: string): Promise<GitList<GitRepository>> {
    const connection = await this.requireConnectionByID(connectionID);
    const ctx = await this.contextForConnection(connection);
    return this.providerForInstance(connection.instance).repositories(ctx);
  }

  async repository(reference: GitRepositoryReference): Promise<GitRepository> {
    return this.runMaybeAuthenticated(reference.instance, (ctx) =>
      this.providerForInstance(reference.instance).repository(reference, ctx),
    );
  }

  async branches(repository: GitRepositoryReference): Promise<GitList<GitBranch>> {
    return this.runMaybeAuthenticated(repository.instance, (ctx) =>
      this.providerForInstance(repository.instance).branches(repository, ctx),
    );
  }

  async createRepository(
    request: GitCreateRepositoryRequest,
    connectionID: string,
  ): Promise<GitRepository> {
    const connection = await this.requireConnectionByID(connectionID);
    return this.runAuthenticated(
      connection.instance,
      (ctx) => this.providerForInstance(connection.instance).createRepository(request, ctx),
      connection.id,
    );
  }

  async createBranch(request: GitCreateBranchRequest): Promise<GitBranch> {
    return this.runAuthenticated(request.repository.instance, (ctx) =>
      this.providerForInstance(request.repository.instance).createBranch(request, ctx),
    );
  }

  async deleteBranch(request: GitDeleteBranchRequest): Promise<void> {
    return this.runAuthenticated(request.repository.instance, (ctx) =>
      this.providerForInstance(request.repository.instance).deleteBranch(request, ctx),
    );
  }

  async forkRepository(
    reference: GitRepositoryReference,
    connectionID: string,
  ): Promise<GitRepository> {
    const connection = await this.requireConnectionByID(connectionID);
    return this.runAuthenticated(
      connection.instance,
      (ctx) => this.providerForInstance(connection.instance).forkRepository(reference, ctx),
      connection.id,
    );
  }

  // MARK: - Pull requests and orchestration

  async createPullRequest(request: GitPullRequestRequest): Promise<GitPullRequest> {
    return this.runAuthenticated(request.repository.instance, (ctx) =>
      this.providerForInstance(request.repository.instance).createPullRequest(request, ctx),
    );
  }

  async submitChange(submission: GitChangeSubmission): Promise<GitChangeResult> {
    const { change, strategy } = submission;
    const repository = change.reference.repository;

    switch (strategy.kind) {
      case "directCommit": {
        const commit = await this.commitFile(change);
        return { commit, usedRepository: repository, usedBranch: change.targetBranch };
      }
      case "existingBranch": {
        const commit = await this.commitFile({ ...change, targetBranch: strategy.branchName });
        return { commit, usedRepository: repository, usedBranch: strategy.branchName };
      }
      case "branchAndPullRequest":
        return this.submitBranchAndPR(change, repository, strategy);
      case "forkAndPullRequest":
        return this.submitForkAndPR(change, repository, strategy);
      case "automatic": {
        const repo = await this.repository(repository);
        if (repo.permissions.canPush) {
          return this.submitBranchAndPR(change, repository, strategy);
        }
        return this.submitForkAndPR(change, repository, strategy);
      }
    }
  }

  private async submitBranchAndPR(
    change: GitFileChange,
    repository: GitRepositoryReference,
    strategy: { branchName: string; title: string; body?: string; draft?: boolean },
  ): Promise<GitChangeResult> {
    const base = change.baseBranch ?? change.targetBranch ?? (await this.defaultBranch(repository));
    await this.createBranch({ repository, name: strategy.branchName, fromRef: base });
    let commit: GitCommitResult;
    try {
      commit = await this.commitFile({ ...change, targetBranch: strategy.branchName });
    } catch (error) {
      throw GitPontError.partialSubmission(
        { commit: emptyCommit(strategy.branchName), usedRepository: repository, usedBranch: strategy.branchName },
        `Branch "${strategy.branchName}" was created but the commit failed: ${messageOf(error)}`,
      );
    }
    const result: GitChangeResult = { commit, usedRepository: repository, usedBranch: strategy.branchName };
    try {
      result.pullRequest = await this.createPullRequest({
        repository,
        title: strategy.title,
        body: strategy.body,
        sourceBranch: strategy.branchName,
        targetBranch: base,
        draft: strategy.draft,
      });
    } catch (error) {
      throw GitPontError.partialSubmission(result, `Commit succeeded but PR creation failed: ${messageOf(error)}`);
    }
    return result;
  }

  private async submitForkAndPR(
    change: GitFileChange,
    repository: GitRepositoryReference,
    strategy: { branchName: string; title: string; body?: string; draft?: boolean },
  ): Promise<GitChangeResult> {
    const connection = await this.resolveConnection(repository.instance, undefined, false);
    const fork = await this.forkRepository(repository, connection.id);
    await this.pollRepositoryAvailable(fork.reference);
    const base = change.baseBranch ?? change.targetBranch ?? (await this.defaultBranch(repository));
    await this.createBranch({ repository: fork.reference, name: strategy.branchName, fromRef: base });
    const forkChange: GitFileChange = {
      ...change,
      reference: { ...change.reference, repository: fork.reference },
      targetBranch: strategy.branchName,
    };
    const commit = await this.commitFile(forkChange);
    const result: GitChangeResult = { commit, usedRepository: fork.reference, usedBranch: strategy.branchName };
    try {
      result.pullRequest = await this.createPullRequest({
        repository,
        title: strategy.title,
        body: strategy.body,
        sourceBranch: strategy.branchName,
        sourceRepository: fork.reference,
        targetBranch: base,
        draft: strategy.draft,
      });
    } catch (error) {
      throw GitPontError.partialSubmission(result, `Fork commit succeeded but PR creation failed: ${messageOf(error)}`);
    }
    return result;
  }

  private async pollRepositoryAvailable(reference: GitRepositoryReference): Promise<void> {
    for (let attempt = 0; attempt < 10; attempt += 1) {
      try {
        await this.repository(reference);
        return;
      } catch (error) {
        if (error instanceof GitPontError && error.code === "notFound") {
          await this.retryPolicy.sleep(1000);
          continue;
        }
        throw error;
      }
    }
  }

  // MARK: - OAuth

  async startOAuth(request: GitOAuthStartRequest): Promise<GitOAuthStartResult> {
    return this.authProviderForInstance(request.instance).startOAuth(request);
  }

  async completeOAuth(request: GitOAuthCompletionRequest): Promise<GitCredential> {
    return this.authProviderForInstance(request.instance).completeOAuth(request);
  }

  // MARK: - Connections

  async connections(): Promise<GitConnection[]> {
    return this.connectionStore.connections();
  }

  async connection(
    instance: GitProviderInstance,
    preferredConnectionID?: string,
  ): Promise<GitConnection> {
    return this.resolveConnection(instance, preferredConnectionID, false);
  }

  async addConnection(
    instance: GitProviderInstance,
    credential: GitCredential,
    authMethod: GitAuthMethod,
  ): Promise<GitConnection> {
    const account = await this.providerForInstance(instance).account(instance, credential);
    const now = new Date();
    const connection: GitConnection = {
      id: this.generateID(),
      instance,
      accountID: account.id,
      accountLogin: account.login,
      displayName: account.displayName,
      authMethod,
      createdAt: now,
      updatedAt: now,
    };
    await this.connectionStore.save(connection);
    await this.credentialStore.save(credential, connection.id);
    return connection;
  }

  async removeConnection(id: string): Promise<void> {
    await this.credentialStore.deleteCredential(id);
    await this.connectionStore.delete(id);
  }

  // MARK: - Provider registry

  private providerForURL(url: string): GitProvider {
    const provider = this.providers.find((p) => p.canHandle(url));
    if (!provider) throw GitPontError.unsupportedURL(url);
    return provider;
  }

  private providerForInstance(instance: GitProviderInstance): GitProvider {
    const family = familyOf(instance.kind);
    const provider = this.providers.find((p) => familyOf(p.kind) === family);
    if (!provider) throw GitPontError.missingConnection(instance.kind);
    return provider;
  }

  private authProviderForInstance(
    instance: GitProviderInstance,
  ): GitProvider & GitAuthenticationProvider {
    const provider = this.providerForInstance(instance);
    if (!supportsAuthentication(provider)) {
      throw GitPontError.unsupportedCapability(`${provider.displayName} does not support OAuth orchestration`);
    }
    return provider;
  }

  // MARK: - Connection resolution and credentials

  private async connectionsForInstance(instance: GitProviderInstance): Promise<GitConnection[]> {
    const all = await this.connectionStore.connections();
    return all.filter((c) => c.instance.id === instance.id);
  }

  private async resolveConnection(
    instance: GitProviderInstance,
    preferredConnectionID: string | undefined,
    _allowNone: boolean,
  ): Promise<GitConnection> {
    const matches = await this.connectionsForInstance(instance);
    if (preferredConnectionID) {
      const preferred = matches.find((c) => c.id === preferredConnectionID);
      if (preferred) return preferred;
    }
    if (matches.length === 1) return matches[0]!;
    if (matches.length > 1) throw GitPontError.ambiguousConnection(instance.id, matches);
    throw GitPontError.missingConnection(instance.kind);
  }

  private async requireConnectionByID(connectionID: string): Promise<GitConnection> {
    const connection = await this.connectionStore.connection(connectionID);
    if (!connection) throw GitPontError.notFound(`No connection with id ${connectionID}`);
    return connection;
  }

  private async contextForConnection(
    connection: GitConnection,
    forceRefresh = false,
  ): Promise<GitProviderRequestContext> {
    const credential = await this.credentialFor(connection, forceRefresh);
    return { connection, credential };
  }

  private async credentialFor(
    connection: GitConnection,
    forceRefresh: boolean,
  ): Promise<GitCredential | undefined> {
    const credential = await this.credentialStore.loadCredential(connection.id);
    if (!credential) return undefined;
    if (!credential.refreshToken) return credential;
    if (!forceRefresh && !isExpiring(credential)) return credential;
    return this.performRefresh(connection, credential);
  }

  /** Serialized per-connection refresh — the JS analog of the Swift refresh actor. */
  private async performRefresh(
    connection: GitConnection,
    credential: GitCredential,
  ): Promise<GitCredential> {
    const existing = this.refreshInFlight.get(connection.id);
    if (existing) return existing;

    const provider = this.providerForInstance(connection.instance);
    if (!supportsAuthentication(provider)) return credential;

    const promise = (async () => {
      const refreshed = await provider.refreshCredential(credential, connection.instance);
      await this.credentialStore.save(refreshed, connection.id);
      return refreshed;
    })();
    this.refreshInFlight.set(connection.id, promise);
    try {
      return await promise;
    } catch (error) {
      throw GitPontError.authenticationFailed(`Token refresh failed: ${messageOf(error)}`);
    } finally {
      this.refreshInFlight.delete(connection.id);
    }
  }

  /**
   * Run an operation that requires authentication. Resolves the connection,
   * builds a context (refreshing proactively), and on an auth failure performs
   * one forced refresh and retries once.
   */
  private async runAuthenticated<T>(
    instance: GitProviderInstance,
    operation: (context: GitProviderRequestContext) => Promise<T>,
    preferredConnectionID?: string,
  ): Promise<T> {
    const connection = await this.resolveConnection(instance, preferredConnectionID, false);
    const context = await this.contextForConnection(connection);
    if (!context.credential) throw GitPontError.authenticationRequired();
    try {
      return await operation(context);
    } catch (error) {
      if (error instanceof GitPontError && error.code === "authenticationFailed") {
        const retryContext = await this.contextForConnection(connection, true);
        return operation(retryContext);
      }
      throw error;
    }
  }

  /**
   * Run a read operation that prefers authentication but tolerates its absence
   * (public repositories). Still refreshes and retries once on auth failure
   * when a connection exists.
   */
  private async runMaybeAuthenticated<T>(
    instance: GitProviderInstance,
    operation: (context: GitProviderRequestContext) => Promise<T>,
  ): Promise<T> {
    const context = await this.buildContext(instance, { allowNone: true });
    try {
      return await operation(context);
    } catch (error) {
      if (
        context.connection &&
        error instanceof GitPontError &&
        error.code === "authenticationFailed"
      ) {
        const retryContext = await this.contextForConnection(context.connection, true);
        return operation(retryContext);
      }
      throw error;
    }
  }

  private async buildContext(
    instance: GitProviderInstance,
    options: { allowNone: boolean; preferredConnectionID?: string },
  ): Promise<GitProviderRequestContext> {
    const matches = await this.connectionsForInstance(instance);
    let connection: GitConnection | undefined;
    if (options.preferredConnectionID) {
      connection = matches.find((c) => c.id === options.preferredConnectionID);
    }
    if (!connection && matches.length === 1) connection = matches[0];
    if (!connection && matches.length > 1 && !options.allowNone) {
      throw GitPontError.ambiguousConnection(instance.id, matches);
    }
    if (!connection) {
      if (options.allowNone) return {};
      throw GitPontError.missingConnection(instance.kind);
    }
    return this.contextForConnection(connection);
  }

  // MARK: - Small helpers

  private repositoryReferenceFrom(reference: GitURLReference): GitRepositoryReference {
    return { instance: reference.instance, namespace: reference.namespace, name: reference.name };
  }

  private async defaultBranch(repository: GitRepositoryReference): Promise<string> {
    if (repository.defaultBranch) return repository.defaultBranch;
    const repo = await this.repository(repository);
    if (!repo.reference.defaultBranch) {
      throw GitPontError.invalidProviderResponse("Repository has no default branch");
    }
    return repo.reference.defaultBranch;
  }
}

function isExpiring(credential: GitCredential): boolean {
  if (!credential.expiresAt) return false;
  return credential.expiresAt.getTime() - Date.now() <= REFRESH_SKEW_MS;
}

function sameVersion(a: GitRemoteVersion | undefined, b: GitRemoteVersion | undefined): boolean {
  if (a === undefined || b === undefined) return a === b;
  if (a.kind !== b.kind) return false;
  if (a.kind === "blobSHA" && b.kind === "blobSHA") return a.sha === b.sha;
  if (a.kind === "commitID" && b.kind === "commitID") return a.id === b.id;
  if (a.kind === "opaque" && b.kind === "opaque") {
    return a.provider === b.provider && a.value === b.value;
  }
  return false;
}

function emptyCommit(branch: string): GitCommitResult {
  return { commitSHA: "", branch };
}

function messageOf(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}
