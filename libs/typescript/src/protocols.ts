/**
 * Provider, authentication, and storage contracts. Mirrors the Swift
 * `GitProvider`, `GitAuthenticationProvider`, `CredentialStore`, and
 * `ConnectionStore` protocols.
 */

import type {
  GitAccount,
  GitAuthMethod,
  GitBranch,
  GitChangeRequestTerm,
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
  GitProviderCapabilities,
  GitProviderInstance,
  GitProviderKind,
  GitPullRequest,
  GitPullRequestQuery,
  GitPullRequestRequest,
  GitRemoteFile,
  GitRepository,
  GitRepositoryReference,
  GitURLParseResult,
} from "./models.js";
import type {
  GitOAuthCompletionRequest,
  GitOAuthStartRequest,
  GitOAuthStartResult,
} from "./oauth.js";

/** Per-request connection and credential context resolved by the facade. */
export interface GitProviderRequestContext {
  connection?: GitConnection;
  credential?: GitCredential;
}

/** Provider contract for normalized repository, file, branch, fork, and PR ops. */
export interface GitProvider {
  readonly kind: GitProviderKind;
  readonly displayName: string;
  readonly capabilities: GitProviderCapabilities;
  readonly changeRequestTerm: GitChangeRequestTerm;

  canHandle(url: string): boolean;
  parse(url: string): GitURLParseResult;
  account(instance: GitProviderInstance, credential: GitCredential): Promise<GitAccount>;
  repositories(context: GitProviderRequestContext): Promise<GitList<GitRepository>>;
  repository(
    reference: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitRepository>;
  branches(
    repository: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitList<GitBranch>>;
  readFile(reference: GitFileReference, context: GitProviderRequestContext): Promise<GitRemoteFile>;
  listDirectory(
    reference: GitFileReference,
    context: GitProviderRequestContext,
  ): Promise<GitList<GitDirectoryEntry>>;
  commitFile(change: GitFileChange, context: GitProviderRequestContext): Promise<GitCommitResult>;
  deleteFile(
    request: GitFileDeleteRequest,
    context: GitProviderRequestContext,
  ): Promise<GitCommitResult>;
  createBranch(
    request: GitCreateBranchRequest,
    context: GitProviderRequestContext,
  ): Promise<GitBranch>;
  deleteBranch(
    request: GitDeleteBranchRequest,
    context: GitProviderRequestContext,
  ): Promise<void>;
  createRepository(
    request: GitCreateRepositoryRequest,
    context: GitProviderRequestContext,
  ): Promise<GitRepository>;
  forkRepository(
    reference: GitRepositoryReference,
    context: GitProviderRequestContext,
  ): Promise<GitRepository>;
  createPullRequest(
    request: GitPullRequestRequest,
    context: GitProviderRequestContext,
  ): Promise<GitPullRequest>;
  findPullRequest?(
    query: GitPullRequestQuery,
    context: GitProviderRequestContext,
  ): Promise<GitPullRequest | undefined>;
}

/** Provider contract for OAuth start, completion, and credential refresh. */
export interface GitAuthenticationProvider {
  authorizationHeaders(
    credential: GitCredential,
    authMethod: GitAuthMethod,
  ): Record<string, string>;
  startOAuth(request: GitOAuthStartRequest): Promise<GitOAuthStartResult>;
  completeOAuth(request: GitOAuthCompletionRequest): Promise<GitCredential>;
  refreshCredential(
    credential: GitCredential,
    instance: GitProviderInstance,
  ): Promise<GitCredential>;
}

export function supportsAuthentication(
  provider: GitProvider,
): provider is GitProvider & GitAuthenticationProvider {
  const candidate = provider as Partial<GitAuthenticationProvider>;
  return (
    typeof candidate.startOAuth === "function" &&
    typeof candidate.completeOAuth === "function" &&
    typeof candidate.refreshCredential === "function"
  );
}

/** Storage abstraction for provider credentials (secrets). */
export interface CredentialStore {
  save(credential: GitCredential, connectionID: string): Promise<void>;
  loadCredential(connectionID: string): Promise<GitCredential | undefined>;
  deleteCredential(connectionID: string): Promise<void>;
}

/** Storage abstraction for provider connection metadata (no secrets). */
export interface ConnectionStore {
  save(connection: GitConnection): Promise<void>;
  connections(): Promise<GitConnection[]>;
  connection(id: string): Promise<GitConnection | undefined>;
  delete(id: string): Promise<void>;
}
