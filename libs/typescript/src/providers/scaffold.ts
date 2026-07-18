/**
 * Scaffold providers for GitLab, Forgejo/Gitea, and Bitbucket.
 *
 * These declare the correct identity, capabilities, and host routing
 * (`canHandle`) so the facade's provider registry works, but their operations
 * throw `unsupportedCapability` until ported from the Swift implementations.
 * The GitHub provider is complete; these are intentional follow-ups.
 */

import { GitPontError } from "../errors.js";
import {
  GitProviderInstances,
  noCapabilities,
  type GitAccount,
  type GitBranch,
  type GitChangeRequestTerm,
  type GitCommitResult,
  type GitCreateBranchRequest,
  type GitCreateRepositoryRequest,
  type GitCredential,
  type GitDeleteBranchRequest,
  type GitDirectoryEntry,
  type GitFileChange,
  type GitFileDeleteRequest,
  type GitFileReference,
  type GitList,
  type GitProviderCapabilities,
  type GitProviderInstance,
  type GitProviderKind,
  type GitPullRequest,
  type GitPullRequestRequest,
  type GitRemoteFile,
  type GitRepository,
  type GitRepositoryReference,
  type GitURLParseResult,
} from "../models.js";
import type { GitProvider, GitProviderRequestContext } from "../protocols.js";
import { hostOf } from "../url.js";

const NOT_IMPLEMENTED = "This provider is scaffolded; port its implementation from the Swift kit.";

abstract class ScaffoldProvider implements GitProvider {
  abstract readonly kind: GitProviderKind;
  abstract readonly displayName: string;
  abstract readonly changeRequestTerm: GitChangeRequestTerm;
  readonly capabilities: GitProviderCapabilities = noCapabilities();

  protected readonly instances: GitProviderInstance[];

  constructor(instances: GitProviderInstance[]) {
    this.instances = instances;
  }

  canHandle(url: string): boolean {
    const host = hostOf(url);
    if (!host) return false;
    return this.instances.some((instance) => hostOf(instance.baseURL) === host);
  }

  parse(_url: string): GitURLParseResult {
    throw GitPontError.unsupportedCapability(NOT_IMPLEMENTED);
  }

  account(_instance: GitProviderInstance, _credential: GitCredential): Promise<GitAccount> {
    return this.unimplemented();
  }

  repositories(_context: GitProviderRequestContext): Promise<GitList<GitRepository>> {
    return this.unimplemented();
  }

  repository(
    _reference: GitRepositoryReference,
    _context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    return this.unimplemented();
  }

  branches(
    _repository: GitRepositoryReference,
    _context: GitProviderRequestContext,
  ): Promise<GitList<GitBranch>> {
    return this.unimplemented();
  }

  readFile(
    _reference: GitFileReference,
    _context: GitProviderRequestContext,
  ): Promise<GitRemoteFile> {
    return this.unimplemented();
  }

  listDirectory(
    _reference: GitFileReference,
    _context: GitProviderRequestContext,
  ): Promise<GitList<GitDirectoryEntry>> {
    return this.unimplemented();
  }

  commitFile(_change: GitFileChange, _context: GitProviderRequestContext): Promise<GitCommitResult> {
    return this.unimplemented();
  }

  deleteFile(
    _request: GitFileDeleteRequest,
    _context: GitProviderRequestContext,
  ): Promise<GitCommitResult> {
    return this.unimplemented();
  }

  createBranch(
    _request: GitCreateBranchRequest,
    _context: GitProviderRequestContext,
  ): Promise<GitBranch> {
    return this.unimplemented();
  }

  deleteBranch(
    _request: GitDeleteBranchRequest,
    _context: GitProviderRequestContext,
  ): Promise<void> {
    return this.unimplemented();
  }

  createRepository(
    _request: GitCreateRepositoryRequest,
    _context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    return this.unimplemented();
  }

  forkRepository(
    _reference: GitRepositoryReference,
    _context: GitProviderRequestContext,
  ): Promise<GitRepository> {
    return this.unimplemented();
  }

  createPullRequest(
    _request: GitPullRequestRequest,
    _context: GitProviderRequestContext,
  ): Promise<GitPullRequest> {
    return this.unimplemented();
  }

  private unimplemented(): Promise<never> {
    return Promise.reject(GitPontError.unsupportedCapability(NOT_IMPLEMENTED));
  }
}

/** GitLab.com and self-hosted GitLab (scaffold). */
export class GitLabProvider extends ScaffoldProvider {
  readonly kind: GitProviderKind = "gitLabCloud";
  readonly displayName = "GitLab";
  readonly changeRequestTerm: GitChangeRequestTerm = "mergeRequest";

  constructor(instances: GitProviderInstance[] = [GitProviderInstances.gitLabCloud]) {
    super(instances);
  }
}

/** Forgejo, Gitea, and Codeberg (scaffold). */
export class ForgeProvider extends ScaffoldProvider {
  readonly kind: GitProviderKind = "forgejo";
  readonly displayName = "Forgejo/Gitea";
  readonly changeRequestTerm: GitChangeRequestTerm = "pullRequest";

  constructor(instances: GitProviderInstance[] = [GitProviderInstances.codeberg]) {
    super(instances);
  }
}

/** Bitbucket Cloud (scaffold). */
export class BitbucketProvider extends ScaffoldProvider {
  readonly kind: GitProviderKind = "bitbucketCloud";
  readonly displayName = "Bitbucket";
  readonly changeRequestTerm: GitChangeRequestTerm = "pullRequest";

  constructor(instances: GitProviderInstance[] = [GitProviderInstances.bitbucketCloud]) {
    super(instances);
  }
}
